-- | The worked example behind @docs\/first-binding.md@.
--
-- That page is a newcomer's first contact with the library, so its code is kept here
-- as a compiled and tested module rather than only in Markdown. A change to either has
-- to be mirrored in the other, and this suite is what catches it if it is not.
--
-- Both C functions come from libm, so the tutorial needs no C library beyond what a
-- GHC install already links.
module Test.Binding.Combinators.FirstBinding (tests) where

-- The (..) matters: a 'foreign import' can only marshal a newtype whose data
-- constructor is in scope, so importing the type alone fails to compile.
import Foreign.C.Types (CDouble (..), CInt (..))
import Foreign.Ptr (Ptr)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

import Binding.Combinators (input, output, resultPure, toHighLevel)
import Binding.Combinators.Auto (auto)
import Binding.Combinators.Marshaller (scalar, unmarshalOutPure)

{-------------------------------------------------------------------------------
  The low-level bindings

  Hand-written here. A generated binding is the same thing with hs-bindgen's types
  in place of the raw ones.
-------------------------------------------------------------------------------}

-- | @double frexp(double x, int *exp)@: split @x@ into a mantissa and an exponent,
-- returning the mantissa and writing the exponent into the out-parameter.
foreign import ccall unsafe "math.h frexp"
  c_frexp :: CDouble -> Ptr CInt -> IO CDouble

-- | @double hypot(double x, double y)@.
foreign import ccall unsafe "math.h hypot"
  c_hypot :: CDouble -> CDouble -> IO CDouble

{-------------------------------------------------------------------------------
  The wrappers
-------------------------------------------------------------------------------}

-- | One combinator per C argument, then a closer. The assembler receives the
-- out-parameter first and the C return value second, which is spec order.
hsFrexp :: Double -> IO (Int, Double)
hsFrexp = toHighLevel c_frexp
        $ input  (scalar realToFrac)
        $ output (unmarshalOutPure fromIntegral)
        $ resultPure (\e m -> (e, realToFrac m))

-- | The same binding with every combinator left to 'auto', which it can write in
-- full because nothing here needs a decision.
hsHypot :: Double -> Double -> IO Double
hsHypot = toHighLevel c_hypot auto

{-------------------------------------------------------------------------------
  Tests
-------------------------------------------------------------------------------}

tests :: TestTree
tests = testGroup "first binding (docs/first-binding.md)"
    [ testCase "hsFrexp splits 8.0 into 0.5 and 4" $
        hsFrexp 8.0 >>= (@?= (4, 0.5))
    , testCase "hsFrexp splits 0.5 into 0.5 and 0" $
        hsFrexp 0.5 >>= (@?= (0, 0.5))
    , testCase "hsHypot 3 4 is 5" $
        hsHypot 3.0 4.0 >>= (@?= 5.0)
    ]
