{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE ViewPatterns #-}
-- | Module used for loading & writing \'Portable Network Graphics\' (PNG)
-- files. The API has two layers, the high level, which load the image without
-- looking deeply about it and the low level, allowing access to data chunks contained
-- in the PNG image.
--
-- For general use, please use 'decodePng' function.
--
-- The loader has been validated against the pngsuite (http://www.libpng.org/pub/png/pngsuite.html)
module Codec.Picture.Png( -- * High level functions
                          PngSavable( .. )

                        , decodePng
                        , writePng
                        , encodePalettedPng
                        , encodeDynamicPng
                        , writeDynamicPng

                        ) where

import Control.Applicative( (<$>) )
import Control.Monad( forM_, foldM_, when )
import Control.Monad.ST( ST, runST )
import Data.Binary( Binary( get) )

import qualified Data.Vector.Storable as V
import qualified Data.Vector.Storable.Mutable as M
import Data.Bits( (.&.), (.|.), unsafeShiftL, unsafeShiftR )
import Data.List( find, zip4 )
import Data.Word( Word8, Word16, Word32 )
import qualified Codec.Compression.Zlib as Z
import qualified Data.ByteString as B
import qualified Data.ByteString.Unsafe as BU
import qualified Data.ByteString.Lazy as Lb
import Foreign.Storable ( Storable )

import Codec.Picture.Types
import Codec.Picture.Png.Type
import Codec.Picture.Png.Export
import Codec.Picture.InternalHelper

-- | Simple structure used to hold information about Adam7 deinterlacing.
-- A structure is used to avoid pollution of the module namespace.
data Adam7MatrixInfo = Adam7MatrixInfo
    { adam7StartingRow  :: [Int]
    , adam7StartingCol  :: [Int]
    , adam7RowIncrement :: [Int]
    , adam7ColIncrement :: [Int]
    , adam7BlockHeight  :: [Int]
    , adam7BlockWidth   :: [Int]
    }

-- | The real info about the matrix.
adam7MatrixInfo :: Adam7MatrixInfo
adam7MatrixInfo = Adam7MatrixInfo
    { adam7StartingRow  = [0, 0, 4, 0, 2, 0, 1]
    , adam7StartingCol  = [0, 4, 0, 2, 0, 1, 0]
    , adam7RowIncrement = [8, 8, 8, 4, 4, 2, 2]
    , adam7ColIncrement = [8, 8, 4, 4, 2, 2, 1]
    , adam7BlockHeight  = [8, 8, 4, 4, 2, 2, 1]
    , adam7BlockWidth   = [8, 4, 4, 2, 2, 1, 1]
    }

unparsePngFilter :: Word8 -> Either String PngFilter
{-# INLINE unparsePngFilter #-}
unparsePngFilter 0 = Right FilterNone
unparsePngFilter 1 = Right FilterSub
unparsePngFilter 2 = Right FilterUp
unparsePngFilter 3 = Right FilterAverage
unparsePngFilter 4 = Right FilterPaeth
unparsePngFilter _ = Left "Invalid scanline filter"

getBounds :: (Monad m, Storable a) => M.STVector s a -> m (Int, Int)
{-# INLINE getBounds #-}
getBounds v = return (0, M.length v - 1)

-- | Apply a filtering method on a reduced image. Apply the filter
-- on each line, using the previous line (the one above it) to perform
-- some prediction on the value.
pngFiltering :: LineUnpacker s -> Int -> (Int, Int)    -- ^ Image size
             -> B.ByteString -> Int
             -> ST s Int
pngFiltering _ _ (imgWidth, imgHeight) _str initialIdx
        | imgWidth <= 0 || imgHeight <= 0 = return initialIdx
pngFiltering unpacker beginZeroes (imgWidth, imgHeight) str initialIdx = do
    thisLine <- M.replicate (beginZeroes + imgWidth) 0
    otherLine <- M.replicate (beginZeroes + imgWidth) 0
    let folder            _          _  lineIndex !idx | lineIndex >= imgHeight = return idx
        folder previousLine currentLine lineIndex !idx = do
               let byte = str `BU.unsafeIndex` idx
               let lineFilter = case unparsePngFilter byte of
                       Right FilterNone    -> filterNone
                       Right FilterSub     -> filterSub
                       Right FilterAverage -> filterAverage
                       Right FilterUp      -> filterUp
                       Right FilterPaeth   -> filterPaeth
                       _ -> filterNone
               idx' <- lineFilter previousLine currentLine $ idx + 1
               unpacker lineIndex (stride, currentLine)
               folder currentLine previousLine (lineIndex + 1) idx'

    folder thisLine otherLine (0 :: Int) initialIdx

    where stride = fromIntegral beginZeroes
          lastIdx = beginZeroes + imgWidth - 1

          -- The filter implementation are... well non-idiomatic
          -- to say the least, but my benchmarks proved me one thing,
          -- they are faster than mapM_, gained something like 5% with
          -- a rewrite from mapM_ to this direct version
          filterNone, filterSub, filterUp, filterPaeth,
                filterAverage :: PngLine s -> PngLine s -> Int -> ST s Int
          filterNone !_previousLine !thisLine = inner beginZeroes
            where inner idx !readIdx
                            | idx > lastIdx = return readIdx
                            | otherwise = do let byte = str `BU.unsafeIndex` readIdx
                                             (thisLine `M.unsafeWrite` idx) byte
                                             inner (idx + 1) $ readIdx + 1

          filterSub !_previousLine !thisLine = inner beginZeroes
            where inner idx !readIdx
                            | idx > lastIdx = return readIdx
                            | otherwise = do let byte = str `BU.unsafeIndex` readIdx
                                             val <- thisLine `M.unsafeRead` (idx - stride)
                                             (thisLine `M.unsafeWrite` idx) $ byte + val
                                             inner (idx + 1) $ readIdx + 1

          filterUp !previousLine !thisLine = inner beginZeroes
            where inner idx !readIdx
                            | idx > lastIdx = return readIdx
                            | otherwise = do let byte = str `BU.unsafeIndex` readIdx
                                             val <- previousLine `M.unsafeRead` idx
                                             (thisLine `M.unsafeWrite` idx) $ val + byte
                                             inner (idx + 1) $ readIdx + 1

          filterAverage !previousLine !thisLine = inner beginZeroes
            where inner idx !readIdx
                            | idx > lastIdx = return readIdx
                            | otherwise = do let byte = str `BU.unsafeIndex` readIdx
                                             valA <- thisLine `M.unsafeRead` (idx - stride)
                                             valB <- previousLine `M.unsafeRead` idx
                                             let a' = fromIntegral valA
                                                 b' = fromIntegral valB
                                                 average = fromIntegral ((a' + b') `div` (2 :: Word16)) 
                                                 writeVal = byte + average 
                                             (thisLine `M.unsafeWrite` idx) $ writeVal
                                             inner (idx + 1) $ readIdx + 1

          filterPaeth !previousLine !thisLine = inner beginZeroes
            where inner idx !readIdx
                            | idx > lastIdx = return readIdx
                            | otherwise = do let byte = str `BU.unsafeIndex` readIdx
                                             valA <- thisLine `M.unsafeRead` (idx - stride)
                                             valC <- previousLine `M.unsafeRead` (idx - stride)
                                             valB <- previousLine `M.unsafeRead` idx
                                             (thisLine `M.unsafeWrite` idx) $ byte + paeth valA valB valC
                                             inner (idx + 1) $ readIdx + 1

                  paeth a b c
                    | pa <= pb && pa <= pc = a
                    | pb <= pc             = b
                    | otherwise            = c
                      where a' = fromIntegral a :: Int
                            b' = fromIntegral b
                            c' = fromIntegral c
                            p = a' + b' - c'
                            pa = abs $ p - a'
                            pb = abs $ p - b'
                            pc = abs $ p - c'
                  
-- | Directly stolen from the definition in the standard (on W3C page),
-- pixel predictor.

type PngLine s = M.STVector s Word8
type LineUnpacker s = Int -> (Int, PngLine s) -> ST s ()

type StrideInfo  = (Int, Int)

type BeginOffset = (Int, Int)


-- | Unpack lines where bit depth is 8
byteUnpacker :: Int -> MutableImage s Word8 -> StrideInfo -> BeginOffset -> LineUnpacker s
byteUnpacker sampleCount (MutableImage{ mutableImageWidth = imgWidth, mutableImageData = arr })
             (strideWidth, strideHeight) (beginLeft, beginTop) h (beginIdx, line) = do
    (_, maxIdx) <- getBounds line
    let realTop = beginTop + h * strideHeight
        lineIndex = realTop * imgWidth
        pixelToRead = min (imgWidth - 1) $ (maxIdx - beginIdx) `div` sampleCount
        inner pixelIndex | pixelIndex > pixelToRead = return ()
                         | otherwise = do
            let destPixelIndex = lineIndex + pixelIndex * strideWidth + beginLeft 
                destSampleIndex = destPixelIndex * sampleCount
                srcPixelIndex = pixelIndex * sampleCount + beginIdx
                perPixel sample | sample >= sampleCount = return ()
                                | otherwise = do
                    val <- line `M.unsafeRead` (srcPixelIndex + sample)
                    let writeIdx = destSampleIndex + sample
                    (arr `M.unsafeWrite` writeIdx) val
                    perPixel (sample + 1)
            perPixel 0
            inner (pixelIndex + 1)
    inner 0
             

-- | Unpack lines where bit depth is 1
bitUnpacker :: Int -> MutableImage s Word8 -> StrideInfo -> BeginOffset -> LineUnpacker s
bitUnpacker _ (MutableImage{ mutableImageWidth = imgWidth, mutableImageData = arr })
              (strideWidth, strideHeight) (beginLeft, beginTop) h (beginIdx, line) = do
    (_, endLine) <- getBounds line
    let realTop = beginTop + h * strideHeight
        lineIndex = realTop * imgWidth
        (lineWidth, subImageRest) = (imgWidth - beginLeft) `divMod` strideWidth
        subPadd | subImageRest > 0 = 1
                | otherwise = 0
        (pixelToRead, lineRest) = (lineWidth + subPadd) `divMod` 8
    forM_ [0 .. pixelToRead - 1] $ \pixelIndex -> do
        val <- line `M.unsafeRead` (pixelIndex  + beginIdx)
        let writeIdx n = lineIndex + (pixelIndex * 8 + n) * strideWidth + beginLeft 
        forM_ [0 .. 7] $ \bit -> (arr `M.unsafeWrite` writeIdx (7 - bit)) ((val `unsafeShiftR` bit) .&. 1)

    when (lineRest /= 0)
         (do val <- line `M.unsafeRead` endLine
             let writeIdx n = lineIndex + (pixelToRead * 8 + n) * strideWidth + beginLeft
             forM_ [0 .. lineRest - 1] $ \bit ->
                (arr `M.unsafeWrite` writeIdx bit) ((val `unsafeShiftR` (7 - bit)) .&. 0x1))


-- | Unpack lines when bit depth is 2
twoBitsUnpacker :: Int -> MutableImage s Word8 -> StrideInfo -> BeginOffset -> LineUnpacker s
twoBitsUnpacker _ (MutableImage{ mutableImageWidth = imgWidth, mutableImageData = arr })
                  (strideWidth, strideHeight) (beginLeft, beginTop) h (beginIdx, line) = do
    (_, endLine) <- getBounds line
    let realTop = beginTop + h * strideHeight
        lineIndex = realTop * imgWidth
        (lineWidth, subImageRest) = (imgWidth - beginLeft) `divMod` strideWidth
        subPadd | subImageRest > 0 = 1
                | otherwise = 0
        (pixelToRead, lineRest) = (lineWidth + subPadd) `divMod` 4

    forM_ [0 .. pixelToRead - 1] $ \pixelIndex -> do
        val <- line `M.unsafeRead` (pixelIndex  + beginIdx)
        let writeIdx n = lineIndex + (pixelIndex * 4 + n) * strideWidth + beginLeft 
        (arr `M.unsafeWrite` writeIdx 0) $ (val `unsafeShiftR` 6) .&. 0x3
        (arr `M.unsafeWrite` writeIdx 1) $ (val `unsafeShiftR` 4) .&. 0x3
        (arr `M.unsafeWrite` writeIdx 2) $ (val `unsafeShiftR` 2) .&. 0x3
        (arr `M.unsafeWrite` writeIdx 3) $ val .&. 0x3

    when (lineRest /= 0)
         (do val <- line `M.unsafeRead` endLine
             let writeIdx n = lineIndex + (pixelToRead * 4 + n) * strideWidth + beginLeft
             forM_ [0 .. lineRest - 1] $ \bit ->
                (arr `M.unsafeWrite` writeIdx bit) ((val `unsafeShiftR` (6 - 2 * bit)) .&. 0x3))

halfByteUnpacker :: Int -> MutableImage s Word8 -> StrideInfo -> BeginOffset -> LineUnpacker s
halfByteUnpacker _ (MutableImage{ mutableImageWidth = imgWidth, mutableImageData = arr })
                   (strideWidth, strideHeight) (beginLeft, beginTop) h (beginIdx, line) = do
    (_, endLine) <- getBounds line
    let realTop = beginTop + h * strideHeight
        lineIndex = realTop * imgWidth
        (lineWidth, subImageRest) = (imgWidth - beginLeft) `divMod` strideWidth
        subPadd | subImageRest > 0 = 1
                | otherwise = 0
        (pixelToRead, lineRest) = (lineWidth + subPadd) `divMod` 2
    forM_ [0 .. pixelToRead - 1] $ \pixelIndex -> do
        val <- line `M.unsafeRead` (pixelIndex  + beginIdx)
        let writeIdx n = lineIndex + (pixelIndex * 2 + n) * strideWidth + beginLeft 
        (arr `M.unsafeWrite` writeIdx 0) $ (val `unsafeShiftR` 4) .&. 0xF
        (arr `M.unsafeWrite` writeIdx 1) $ val .&. 0xF
    
    when (lineRest /= 0)
         (do val <- line `M.unsafeRead` endLine
             let writeIdx = lineIndex + (pixelToRead * 2) * strideWidth + beginLeft 
             (arr `M.unsafeWrite` writeIdx) $ (val `unsafeShiftR` 4) .&. 0xF)

shortUnpacker :: Int -> MutableImage s Word16 -> StrideInfo -> BeginOffset -> LineUnpacker s
shortUnpacker sampleCount (MutableImage{ mutableImageWidth = imgWidth, mutableImageData = arr })
             (strideWidth, strideHeight) (beginLeft, beginTop) h (beginIdx, line) = do
    (_, maxIdx) <- getBounds line
    let realTop = beginTop + h * strideHeight
        lineIndex = realTop * imgWidth
        pixelToRead = min (imgWidth - 1) $ (maxIdx - beginIdx) `div` (sampleCount * 2)
    forM_ [0 .. pixelToRead] $ \pixelIndex -> do
        let destPixelIndex = lineIndex + pixelIndex * strideWidth + beginLeft 
            destSampleIndex = destPixelIndex * sampleCount
            srcPixelIndex = pixelIndex * sampleCount * 2 + beginIdx
        forM_ [0 .. sampleCount - 1] $ \sample -> do
            highBits <- line `M.unsafeRead` (srcPixelIndex + sample * 2 + 0)
            lowBits <- line `M.unsafeRead` (srcPixelIndex + sample * 2 + 1)
            let fullValue = fromIntegral lowBits .|. (fromIntegral highBits `unsafeShiftL` 8)
                writeIdx = destSampleIndex + sample
            (arr `M.unsafeWrite` writeIdx) $ fullValue

-- | Transform a scanline to a bunch of bytes. Bytes are then packed
-- into pixels at a further step.
scanlineUnpacker8 :: Int -> Int -> MutableImage s Word8 -> StrideInfo -> BeginOffset
                 -> LineUnpacker s
scanlineUnpacker8 1 = bitUnpacker
scanlineUnpacker8 2 = twoBitsUnpacker
scanlineUnpacker8 4 = halfByteUnpacker
scanlineUnpacker8 8 = byteUnpacker
scanlineUnpacker8 _ = error "Impossible bit depth"

byteSizeOfBitLength :: Int -> Int -> Int -> Int
byteSizeOfBitLength pixelBitDepth sampleCount dimension = size + (if rest /= 0 then 1 else 0)
   where (size, rest) = (pixelBitDepth * dimension * sampleCount) `quotRem` 8

scanLineInterleaving :: Int -> Int -> (Int, Int) -> (StrideInfo -> BeginOffset -> LineUnpacker s)
                     -> B.ByteString
                     -> ST s ()
scanLineInterleaving depth sampleCount (imgWidth, imgHeight) unpacker str =
    pngFiltering (unpacker (1,1) (0, 0)) strideInfo (byteWidth, imgHeight) str 0 >> return ()
        where byteWidth = byteSizeOfBitLength depth sampleCount imgWidth
              strideInfo | depth < 8 = 1
                         | otherwise = sampleCount * (depth `div` 8)

-- | Given data and image size, recreate an image with deinterlaced
-- data for PNG's adam 7 method.
adam7Unpack :: Int -> Int -> (Int, Int) -> (StrideInfo -> BeginOffset -> LineUnpacker s)
            -> B.ByteString -> ST s ()
adam7Unpack depth sampleCount (imgWidth, imgHeight) unpacker str =
  foldM_ (\i f -> f i) 0 subImages >> return ()
    where Adam7MatrixInfo { adam7StartingRow  = startRows
                          , adam7RowIncrement = rowIncrement
                          , adam7StartingCol  = startCols
                          , adam7ColIncrement = colIncrement } = adam7MatrixInfo

          subImages = 
              [pngFiltering (unpacker (incrW, incrH) (beginW, beginH)) strideInfo (byteWidth, passHeight) str
                            | (beginW, incrW, beginH, incrH) <- zip4 startCols colIncrement startRows rowIncrement
                            , let passWidth = sizer imgWidth beginW incrW
                                  passHeight = sizer imgHeight beginH incrH
                                  byteWidth = byteSizeOfBitLength depth sampleCount passWidth
                            ]
          strideInfo | depth < 8 = 1
                     | otherwise = sampleCount * (depth `div` 8)
          sizer dimension begin increment
            | dimension <= begin = 0
            | otherwise = outDim + (if restDim /= 0 then 1 else 0)
                where (outDim, restDim) = (dimension - begin) `quotRem` increment

-- | deinterlace picture in function of the method indicated
-- in the iHDR
deinterlacer :: PngIHdr -> B.ByteString -> ST s (Either (V.Vector Word8) (V.Vector Word16))
deinterlacer (PngIHdr { width = w, height = h, colourType  = imgKind
                      , interlaceMethod = method, bitDepth = depth  }) str = do
    let compCount = sampleCountOfImageType imgKind 
        arraySize = fromIntegral $ w * h * compCount
        deinterlaceFunction = case method of
            PngNoInterlace -> scanLineInterleaving
            PngInterlaceAdam7 -> adam7Unpack
        iBitDepth = fromIntegral depth
    if iBitDepth <= 8
      then do
        imgArray <- M.new arraySize
        let mutableImage = MutableImage (fromIntegral w) (fromIntegral h) imgArray
        deinterlaceFunction iBitDepth 
                            (fromIntegral compCount)
                            (fromIntegral w, fromIntegral h)
                            (scanlineUnpacker8 iBitDepth (fromIntegral compCount)
                                                         mutableImage)
                            str
        Left <$> V.unsafeFreeze imgArray

      else do
        imgArray <- M.new arraySize
        let mutableImage = MutableImage (fromIntegral w) (fromIntegral h) imgArray
        deinterlaceFunction iBitDepth 
                            (fromIntegral compCount)
                            (fromIntegral w, fromIntegral h)
                            (shortUnpacker (fromIntegral compCount) mutableImage)
                            str
        Right <$> V.unsafeFreeze imgArray

generateGreyscalePalette :: Word8 -> PngPalette
generateGreyscalePalette times = Image possibilities 0 vec
    where possibilities = 2 ^ times - 1
          vec = V.fromListN ((fromIntegral possibilities + 1) * 3) $ concat pixels
          pixels = [[i, i, i] | n <- [0 .. possibilities]
                              , let i = fromIntegral $ n * (255 `div` possibilities)]

sampleCountOfImageType :: PngImageType -> Word32
sampleCountOfImageType PngGreyscale = 1
sampleCountOfImageType PngTrueColour = 3
sampleCountOfImageType PngIndexedColor = 1
sampleCountOfImageType PngGreyscaleWithAlpha = 2
sampleCountOfImageType PngTrueColourWithAlpha = 4

paletteRGBA1, paletteRGBA2, paletteRGBA4 :: PngPalette
paletteRGBA1 = generateGreyscalePalette 1
paletteRGBA2 = generateGreyscalePalette 2
paletteRGBA4 = generateGreyscalePalette 4

{-# INLINE bounds #-}
bounds :: Storable a => V.Vector a -> (Int, Int)
bounds v = (0, V.length v - 1)

applyPalette :: PngPalette -> V.Vector Word8 -> V.Vector Word8
applyPalette pal img = V.fromListN ((initSize + 1) * 3) pixels
    where (_, initSize) = bounds img
          pixels = concat [[r, g, b] | ipx <- V.toList img
                                     , let PixelRGB8 r g b = pixelAt pal (fromIntegral ipx) 0]

applyPaletteWithTransparency :: PngPalette -> Word8 -> V.Vector Word8 -> V.Vector Word8
applyPaletteWithTransparency pal transp img = V.fromListN ((initSize + 1) * 4) pixels
    where (_, initSize) = bounds img
          pixels = concat [ if ipx == transp then [0, 0, 0, 0] else [r, g, b, 255]
                                     | ipx <- V.toList img
                                     , let PixelRGB8 r g b = pixelAt pal (fromIntegral ipx) 0]

-- | Transform a raw png image to an image, without modifying the
-- underlying pixel type. If the image is greyscale and < 8 bits,
-- a transformation to RGBA8 is performed. This should change
-- in the future.
-- The resulting image let you manage the pixel types.
--
-- This function can output the following pixel types :
--
--    * PixelY8
--
--    * PixelY16
--
--    * PixelYA8
--
--    * PixelYA16
--
--    * PixelRGB8
--
--    * PixelRGB16
--
--    * PixelRGBA8
--
--    * PixelRGBA16
--
decodePng :: B.ByteString -> Either String DynamicImage
decodePng byte = do
    rawImg <- runGetStrict get byte
    let ihdr@(PngIHdr { width = w, height = h }) = header rawImg
        compressedImageData =
              Lb.concat [chunkData chunk | chunk <- chunks rawImg
                                        , chunkType chunk == iDATSignature]
        zlibHeaderSize = 1 {- compression method/flags code -}
                       + 1 {- Additional flags/check bits -}
                       + 4 {-CRC-}

        toImage const1 _const2 (Left a) =
            Right . const1 $ Image (fromIntegral w) (fromIntegral h) a
        toImage _const1 const2 (Right a) =
            Right . const2 $ Image (fromIntegral w) (fromIntegral h) a

        palette8 palette [(Lb.uncons -> Just (c,_))] (Left img) =
            Right . ImageRGBA8
                  . Image (fromIntegral w) (fromIntegral h)
                  $ applyPaletteWithTransparency palette c img

        palette8 palette _ (Left img) =
            Right . ImageRGB8
                  . Image (fromIntegral w) (fromIntegral h)
                  $ applyPalette palette img

        palette8 _ _ (Right _) = Left "Invalid bit depth for paleted image"

        transparencyColor =
            [ chunkData chunk | chunk <- chunks rawImg
                              , chunkType chunk == tRNSSignature ]

        unparse _ t PngGreyscale bytes
            | bitDepth ihdr == 1 = unparse (Just paletteRGBA1) t PngIndexedColor bytes
            | bitDepth ihdr == 2 = unparse (Just paletteRGBA2) t PngIndexedColor bytes
            | bitDepth ihdr == 4 = unparse (Just paletteRGBA4) t PngIndexedColor bytes
            | otherwise = toImage ImageY8 ImageY16 $ runST stArray
                where stArray = deinterlacer ihdr bytes

        unparse Nothing _ PngIndexedColor  _ = Left "no valid palette found"
        unparse _ _ PngTrueColour          bytes =
            toImage ImageRGB8 ImageRGB16 $ runST stArray
                where stArray = deinterlacer ihdr bytes
        unparse _ _ PngGreyscaleWithAlpha  bytes =
            toImage ImageYA8 ImageYA16 $ runST stArray
                where stArray = deinterlacer ihdr bytes
        unparse _ _ PngTrueColourWithAlpha bytes =
            toImage ImageRGBA8 ImageRGBA16 $ runST stArray
                where stArray = deinterlacer ihdr bytes
        unparse (Just plte) transparency PngIndexedColor bytes =
            palette8 plte transparency $ runST stArray
                where stArray = deinterlacer ihdr bytes

    if Lb.length compressedImageData <= zlibHeaderSize
       then Left "Invalid data size"
       else let imgData = Z.decompress compressedImageData
       	        parseableData = B.concat $ Lb.toChunks imgData
                palette = case find (\c -> pLTESignature == chunkType c) $ chunks rawImg of
                    Nothing -> Nothing
                    Just p -> case parsePalette p of
                            Left _ -> Nothing
                            Right plte -> Just plte
            in unparse palette transparencyColor (colourType ihdr) parseableData
