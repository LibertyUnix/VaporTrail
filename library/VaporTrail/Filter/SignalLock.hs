{-# LANGUAGE RankNTypes #-}
module VaporTrail.Filter.SignalLock (lockSignal) where

import VaporTrail.Filter.Fourier
import VaporTrail.Filter.Basic
import Data.Machine
import Control.Monad
import Data.Complex
import Data.Foldable
import Control.Category hiding ((.), id)

sigStrength :: Float -> Int -> [Float] -> Float
sigStrength hz sampleRate xs =
  let bin = hz / (fromIntegral sampleRate / fromIntegral dftSize)
      s = magnitude (goertzel bin dftSize xs)
      a = foldl' (\acc x -> acc + abs x) 0 xs / fromIntegral dftSize
  in (s * 2) / fromIntegral dftSize / a

lockChunk :: Category k => Float -> Int -> Plan (k Float) o ([Float], Float)
lockChunk hz sampleRate = do
  c <- replicateM dftSize await
  return (c, sigStrength hz sampleRate c)

acquireSignal :: Category k => Float -> Int -> Plan (k Float) o [Float]
acquireSignal hz sampleRate = do
  (chunk, sigLevel) <- lockChunk hz sampleRate
  if sigLevel < 0.9
    then acquireSignal hz sampleRate
    else return chunk

maintainLock :: Category k => Float -> Int -> Plan (k Float) o [Float]
maintainLock hz sampleRate = do
  (chunk, sigLevel) <- lockChunk hz sampleRate
  if sigLevel < 0.3
    then acquireSignal hz sampleRate
    else return chunk

lockOn :: Float -> Int -> Process Float Float
lockOn hz sampleRate =
  construct $ do
    firstChunk <- acquireSignal hz sampleRate
    forM_ firstChunk yield
    forever $ do
      chunk <- maintainLock hz sampleRate
      forM_ chunk yield

calcSignalNormalizer :: Category k => Plan (k Float) Float (Float -> Float)
calcSignalNormalizer = do
  samples <- replicateM (10 * dftSize) await
  let dco = sum samples / (dftSizeF * 10)
      maxAmp = foldl' (\prev x -> max prev (abs (x - dco))) 0 samples
      normalize x = (x - dco) / maxAmp
  forM_ samples (\sample -> yield (normalize sample))
  return normalize

skipStartupNoise :: Category k => Plan (k Float) o ()
skipStartupNoise = replicateM_ (10 * dftSize) await

normalizeSignal :: Process Float Float
normalizeSignal =
  construct $ do
    normalize <- calcSignalNormalizer
    forever $ do
      x <- await
      yield (normalize x)

dftSize :: Int
dftSize = 192

dftSizeF :: Float
dftSizeF = fromIntegral dftSize

lockSignal :: Int -> Int -> Process Float Float
lockSignal dataRate sampleRate =
  lockOn (fromIntegral dataRate) sampleRate ~> normalizeSignal
