{-# LANGUAGE TypeFamilies, KindSignatures, DataKinds, TypeOperators #-}
{-# LANGUAGE ScopedTypeVariables, FlexibleContexts #-}
{-# LANGUAGE BangPatterns, ForeignFunctionInterface #-}

import           Control.Applicative
import           Control.Monad
import           Data.Foldable
import           Data.Monoid
import           Data.Traversable

import           Data.Char
import           Data.IORef
import           Data.List
import           Data.Maybe
import           Data.Proxy
import           Data.Word

import           System.Clock
import           System.Environment
import           System.IO

import           Options.Applicative

import           Text.Printf

import qualified Data.Binary as LB
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as LB

import           Control.DeepSeq
import           Data.Coerce
import           Debug.Trace
import           GHC.TypeLits

import           Foreign.C
import           Foreign.Ptr
import           System.IO.Unsafe

import qualified Control.Monad.State.Lazy as SL
import           Data.Functor.Identity
import           Data.Random
import           Data.Random.Distribution.Categorical
import           System.Random

import           Data.Vector (Vector)
import qualified Data.Vector.Generic as V
import qualified Data.Vector.Unboxed as U
import qualified Data.Vector.Storable as S
import qualified Data.Vector.Storable.Mutable as M
import qualified Numeric.LinearAlgebra.HMatrix as HM

import qualified Criterion

import           AI.Funn.Flat
import           AI.Funn.LSTM
import           AI.Funn.Mixing
import           AI.Funn.Network
import           AI.Funn.RNN
import           AI.Funn.SGD
import           AI.Funn.Search
import           AI.Funn.SomeNat
import           AI.Funn.Common
import           AI.Funn.Pointed

type Layer = Network Identity

sampleIO :: RVar a -> IO a
sampleIO v = runRVar v StdRandom

blob :: [Double] -> Blob n
blob xs = Blob (V.fromList xs)

deepseqM :: (Monad m, NFData a) => a -> m ()
deepseqM x = deepseq x (return ())

addParameters :: Parameters -> Parameters -> Parameters
addParameters (Parameters x) (Parameters y) = Parameters (x + y)

scaleParameters :: Double -> Parameters -> Parameters
scaleParameters x (Parameters y) = Parameters (HM.scale x y)



foreign import ccall "vector_add" ffi_vector_add :: CInt -> Ptr Double -> Ptr Double -> IO ()

{-# NOINLINE vector_add #-}
vector_add :: M.IOVector Double -> S.Vector Double -> IO ()
vector_add tgt src = do M.unsafeWith tgt $ \tbuf -> do
                          S.unsafeWith src $ \sbuf -> do
                            ffi_vector_add (fromIntegral n) tbuf sbuf
  where
    n = V.length src

addToIO :: M.IOVector Double -> [Parameters] -> IO ()
addToIO target ys = go target (coerce ys :: [S.Vector Double])
  where
    go target [] = return ()
    go target (v:vs) = do
      vector_add target v
      go (M.drop (V.length v) target) vs

sumParameterList :: Foldable f => Int -> f [Parameters] -> Parameters
sumParameterList n xss = Parameters $ unsafePerformIO go
  where
    go = do target <- M.replicate n 0
            traverse_ (addToIO target) xss
            V.unsafeFreeze target




norm :: Parameters -> Double
norm (Parameters xs) = sqrt $ V.sum $ V.map (^2) xs

clipping_limit :: Double
clipping_limit = 0.04

clip :: Parameters -> Parameters -> Parameters
clip ps ds
  | V.any (\x -> isInfinite x || isNaN x) (getParameters ds) =
      trace ("Infinity in gradient, reducing") $ scaleParameters (0.01) ps
  | total > rel * clipping_limit =
      trace ("clipping " ++ show (total, rel*clipping_limit)) $ scaleParameters (clipping_limit*rel/total) ds
  | otherwise = ds
  where
    rel = sqrt $ fromIntegral (V.length (getParameters ds))
    -- xs1 = V.map (max (-50) . min 50) xs
    total = norm ds

dropL :: (Monad m, da ~ D a, VectorSpace da) => Network m (a, b) b
dropL = Network ev 0 (pure mempty)
  where
    ev _ (a, b) = let backward db = return ((unit, db), [])
                      in return (b, 0, backward)

dropR :: (Monad m, da ~ D a, VectorSpace da) => Network m (b, a) b
dropR = swap >>> dropL


dup :: (Monad m, da ~ D a, VectorSpace da) => Network m a (a, a)
dup = Network ev 0 (pure mempty)
  where
    ev _ a = let backward (da1,da2) = return ((da1 ## da2), [])
             in return ((a,a), 0, backward)

descent :: forall a. Network Identity a () -> Parameters -> IO a -> (Int -> Parameters -> Double -> IO ()) -> IO ()
descent network par_initial source save = do
  inputs <- getSources
  let
    -- config = SGDConfig 0.01 0.9 scaleParameters addParameters run
    -- results = runIdentity (sgd config par_initial inputs)
    config = SSVRGConfig 0.1 [round (min 1000 ((2**x) * 2) :: Double) | x <- [0..]] 1000 our_sum scaleParameters addParameters run
    results = runIdentity (ssvrg config par_initial inputs)
    go (i, (cost, par, dpar)) = do
      when (i `mod` 100 == 0) $ do
        let
          gpn = abs (norm dpar / norm par)
        putStrLn $ "grad/param norm: " ++ show gpn
      save i par cost
  traverse_ go (zip [0..] results)

  where
    getSources = do x <- source
                    xs <- unsafeInterleaveIO getSources
                    return (x:xs)

    our_sum pars = sumParameterList (params network) (map pure pars)

    run par a = do
      ((), cost, k) <- evaluate network par a
      (da, dpar) <- k ()
      return (cost, clip par (fold dpar))

feedR :: (Monad m) => b -> Network m (a,b) c -> Network m a c
feedR b network = Network ev (params network) (initialise network)
  where
    ev pars a = do (c, cost, k) <- evaluate network pars (a, b)
                   let backward dc = do
                         ((da, _), dpar) <- k dc
                         return (da, dpar)
                   return (c, cost, backward)

feedL :: (Monad m) => a -> Network m (a,b) c -> Network m b c
feedL a network = feedR a (swap >>> network)

checkGradient :: forall a. (KnownNat a) => Network Identity (Blob a) () -> IO ()
checkGradient network = do parameters <- sampleIO (initialise network)
                           input <- sampleIO (generateBlob $ uniform 0 1)
                           let (e, d_input, d_parameters) = runNetwork' network parameters input
                           d1 <- sampleIO (V.replicateM                a (uniform (-ε) ε))
                           d2 <- sampleIO (V.replicateM (params network) (uniform (-ε) ε))
                           let parameters' = Parameters (V.zipWith (+) (getParameters parameters) d2)
                               input' = input ## Blob d1
                           let (e', _, _) = runNetwork' network parameters' input'
                               δ_expected = sum (V.toList $ V.zipWith (*) (getBlob d_input) d1)
                                            + sum (V.toList $ V.zipWith (*) (getParameters d_parameters) d2)
                           print (e' - e, δ_expected)

  where
    a = fromIntegral (natVal (Proxy :: Proxy a)) :: Int
    ε = 0.000001


sampleRNN :: s -> (Blob 256) -> Layer (s, Blob 256) (s, Blob 256) -> Parameters -> [Word8]
sampleRNN s cfirst layer p_layer = SL.evalState (go s cfirst) (mkStdGen 1)
  where
    go s cprev = do
      let (new_s, t) = runNetwork_ layer p_layer (s, cprev)
          exps = V.map exp (getBlob t)
          factor = 1 / V.sum exps
          ps = V.map (*factor) exps
      c <- runRVar (categorical $ zip (V.toList ps) [0..]) StdRandom
      rest <- go new_s (oneofn V.! fromIntegral c)
      return (c : rest)

    oneofn :: Vector (Blob 256)
    oneofn = V.generate 256 (\i -> blob (replicate i 0 ++ [1] ++ replicate (255 - i) 0))

-- beamRNN :: Int -> s -> (Blob 256) -> Network Identity (s, Blob 256) (s, t) -> Parameters -> Network Identity t (Blob 256) -> Parameters -> [Word8]
-- beamRNN n s cfirst layer p_layer final p_final = beamSearch n (s, cfirst) (stepRNN layer p_layer final p_final)

-- stepRNN :: Network Identity (s, Blob 256) (s, t) -> Parameters -> Network Identity t (Blob 256) -> Parameters
--            -> ((s, Blob 256) -> [(Word8, (s, Blob 256), Double)])
-- stepRNN layer p_layer final p_final = go
--   where
--     go (s, cprev) = let (new_s, t) = runNetwork_ layer p_layer (s, cprev)
--                         logps = getBlob $ runNetwork_ final p_final t
--                         factor = -log (V.sum $ V.map exp $ logps)
--                         ps = V.map (factor +) logps
--                     in [(fromIntegral c, (new_s, oneofn V.! c), ps V.! c + (case chr c of { ' ' -> -0.3; '-' -> -0.1; _ -> 0 })) | c <- [10..127]]

--     oneofn :: Vector (Blob 256)
--     oneofn = V.generate 256 (\i -> blob (replicate i 0 ++ [1] ++ replicate (255 - i) 0))

(>&>) :: (Monad m) => Network m (x1,a) (x2,b) -> Network m (y1,b) (y2,c) -> Network m ((x1,y1), a) ((x2,y2), c)
(>&>) one two = let two' = assocR >>> right two >>> assocL
                    one' = left swap >>> assocR >>> right one >>> assocL >>> left swap
                in one' >>> two'

data LayerChoice = FCLayer | HierLayer Int | Papillon Int | Poly (Int,Int)
                 deriving (Show)

data Options = Options LayerChoice Commands
             deriving (Show)

data Commands = Train (Maybe FilePath) FilePath (Maybe FilePath) (Maybe FilePath) Int
              | Sample FilePath (Maybe Int)
              | CheckDeriv
              deriving (Show)

type N = 50
type LayerH h a b = Network Identity (h, a) (h, b)

instance LB.Binary (Blob n) where
  put (Blob xs) = putVector putDouble xs
  get = Blob <$> getVector getDouble

stack :: (Monad m) => Network m (s, a) (s, b) -> Network m (t, b) (t, c) -> Network m ((s,t), a) ((s,t), c)
stack one two = left swap >>> assocR -- (t, (s,a))
                >>> right one -- (t, (s,b))
                >>> assocL >>> left swap >>> assocR -- (s, (t, b))
                >>> right two -- (s, (t, c))
                >>> assocL -- ((s,t), c)

type H = (Blob N, Blob N)

loop :: (Monad m, db ~ D b, VectorSpace db) => Network m (s, (b, a)) (s, b) -> Network m ((s,b), a) ((s,b), b)
loop network = assocR >>> network >>> right dup >>> assocL

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering

  let optparser = (info (Options
                         <$> (const FCLayer <$> switch (long "fclayer")
                              <|> HierLayer <$> option auto (long "hierlayer")
                              <|> Papillon <$> option auto (long "papillon")
                              <|> Poly <$> option auto (long "poly"))
                         <*> (subparser $
                              command "train"
                              (info (Train
                                     <$> optional (strOption (long "initial" <> action "file"))
                                     <*> strOption (long "input" <> action "file")
                                     <*> optional (strOption (long "output" <> action "file"))
                                     <*> optional (strOption (long "log" <> action "file"))
                                     <*> (option auto (long "chunksize") <|> pure 50)
                                    )
                               (progDesc "Train NN."))
                              <>
                              command "sample"
                              (info (Sample
                                     <$> strOption (long "snapshot" <> action "file")
                                     <*> optional (option auto (long "length")))
                               (progDesc "Sample output."))
                              <>
                              command "check"
                              (info (pure CheckDeriv)
                               (progDesc "Check Derivatives."))
                             ))
                         fullDesc)

  opts <- customExecParser (prefs showHelpOnError) optparser

  let
    connectingLayer :: (KnownNat a, KnownNat b, Monad m) => Network m (Blob a) (Blob b)
    connectingLayer = case opts of
                       Options FCLayer _ -> fcLayer
                       Options (HierLayer n) _ -> hierLayerN n
                       Options (Papillon n) _ -> papillonLayer n
                       Options (Poly (n,k)) _ -> polyLayer' n k

    step1 :: Layer (H, Blob 256) (H, Blob N)
    step1 = assocR >>> right (mergeLayer >>> connectingLayer >>> sigmoidLayer) >>> lstmLayer >>> right dup >>> assocL

    step2 :: Layer (H, Blob N) (H, Blob N)
    step2 = assocR >>> right (mergeLayer >>> connectingLayer >>> sigmoidLayer) >>> lstmLayer >>> right dup >>> assocL

    finalx :: Layer (Blob N) (Blob 256)
    finalx = connectingLayer

    layer :: Layer ((H,H), Blob 256) ((H,H), Blob 256)
    layer = (step1 `stack` step2) >>> right finalx

    network :: Layer (Vector (Blob 256)) (Vector (Blob 256))
    network = feedL unit (rnnX layer) >>> dropL

    train :: Layer (Vector (Blob 256), Vector Int) ()
    train = left network >>> zipWithNetwork_ softmaxCost

    oneofn :: Vector (Blob 256)
    oneofn = V.generate 256 (\i -> blob (replicate i 0 ++ [1] ++ replicate (255 - i) 0))

  print (params train)

  let Options _ command = opts

  case command of
   Train initpath input savefile logfile chunkSize -> do
     initial_par <- case initpath of
       -- Just path -> read <$> readFile path
       Just path -> LB.decode <$> LB.readFile path
       Nothing -> sampleIO (initialise train)

     deepseqM initial_par

     text <- B.readFile input

     running_average <- newIORef 0
     running_count <- newIORef 0

     startTime <- getTime ProcessCPUTime

     logfp <- case logfile of
               Just logfile -> Just <$> openFile logfile WriteMode
               Nothing -> pure Nothing

     let
       α :: Double
       α = 1 - 1 / 50

       tvec = V.fromList (B.unpack text) :: U.Vector Word8
       ovec = V.map (\c -> oneofn V.! (fromIntegral c)) (V.convert tvec) :: Vector (Blob 256)

       source :: IO (Vector (Blob 256), Vector Int)
       source = do s <- sampleIO (uniform 0 (V.length tvec - chunkSize))
                   let
                     input = (oneofn V.! 0) `V.cons` V.slice s (chunkSize - 1) ovec
                     output = V.map fromIntegral (V.convert (V.slice s chunkSize tvec))
                   return (input, output)

       save i par c = do

         when (not (isInfinite c)) $ do
           modifyIORef' running_average (\x -> (α*x + (1 - α)*c))
           modifyIORef' running_count (\x -> (α*x + (1 - α)*1))

         x <- do q <- readIORef running_average
                 w <- readIORef running_count
                 return ((q / w) / fromIntegral chunkSize)

         when (i `mod` 50 == 0) $ do
           now <- getTime ProcessCPUTime
           let tdiff = fromIntegral (timeSpecAsNanoSecs (now - startTime)) / (10^9) :: Double
           putStrLn $ printf "[% 11.4f]  %i  %f  %f" tdiff i x (c / fromIntegral (chunkSize-1))
           case logfp of
            Just fp -> hPutStrLn fp (printf "%f %i %f" tdiff i x) >> hFlush fp
            Nothing -> return ()

         when (i `mod` 1000 == 0) $ do
           case savefile of
            Just savefile -> do
              LB.writeFile (printf "%s-%6.6i-%5.5f.bin" savefile i x) $ LB.encode par
              LB.writeFile (savefile ++ "-latest.bin") $ LB.encode par
            Nothing -> return ()
           LB.putStrLn . LB.pack . take 500 $ sampleRNN unit (oneofn V.! 0) layer par

     deepseqM (tvec, ovec)

     descent train initial_par source save

   Sample initpath length -> do
     p_layer <- LB.decode <$> LB.readFile initpath
     deepseqM p_layer

     let text = sampleRNN unit (oneofn V.! 0) layer p_layer
     LB.putStrLn . LB.pack $ case length of
                 Just n -> take n text
                 Nothing -> text

   CheckDeriv -> do
    checkGradient $ splitLayer >>> left (hierLayerN 4 :: Layer (Blob 50) (Blob 100)) >>> (quadraticCost :: Network Identity (Blob 100, Blob 100) ())

    checkGradient $ splitLayer >>> (quadraticCost :: Network Identity (Blob 10, Blob 10) ())

    checkGradient $ (fcLayer :: Network Identity (Blob 20) (Blob 20)) >>> splitLayer >>> (quadraticCost :: Network Identity (Blob 10, Blob 10) ())

    checkGradient $ splitLayer >>> (lstmLayer :: Network Identity (Blob 1, Blob 4) (Blob 1, Blob 1)) >>> quadraticCost

    checkGradient $ splitLayer >>> left (freeLayer :: Layer (Blob 50) (Blob 100)) >>> (quadraticCost :: Network Identity (Blob 100, Blob 100) ())

    checkGradient $ splitLayer >>> left (hierLayer :: Layer (Blob 50) (Blob 100)) >>> (quadraticCost :: Network Identity (Blob 100, Blob 100) ())

    checkGradient $ (feedR 7 softmaxCost :: Layer (Blob 10) ())

    checkGradient $ runPointed $ \(a :: Ref s (Blob 10)) -> do
      b <- feed a fcLayer
      ab <- joinP a b
      c <- feed ab quadraticCost
      return (c :: Ref s ())

    let benchNetwork net v = do
          pars <- sampleIO (initialise net)
          let f x = runIdentity $ do (o, c, k) <- evaluate net pars x
                                     (da, dp) <- k unit
                                     return (o, c, da, dp)
          -- return $ Criterion.nf (runNetwork_ net pars) v
          return $ Criterion.nf f v

    Criterion.benchmark =<< benchNetwork (freeLayer >>> biasLayer :: Network Identity (Blob 511) (Blob 511)) unit
    Criterion.benchmark =<< benchNetwork (fcLayer :: Network Identity (Blob 511) (Blob 511)) unit
    Criterion.benchmark =<< benchNetwork (hierLayer :: Network Identity (Blob 511) (Blob 511)) unit
