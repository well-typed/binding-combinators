-- | The @ToHighLevel@ combinator test suite, grouped by concern.
module Test.Binding.Combinators (tests) where

import Test.Tasty (TestTree, testGroup)

import Test.Binding.Combinators.Auto qualified as Auto
import Test.Binding.Combinators.Closers qualified as Closers
import Test.Binding.Combinators.Errors qualified as Errors
import Test.Binding.Combinators.FirstBinding qualified as FirstBinding
import Test.Binding.Combinators.Inputs qualified as Inputs
import Test.Binding.Combinators.Outputs qualified as Outputs
import Test.Binding.Combinators.Scratch qualified as Scratch
import Test.Binding.Combinators.Struct qualified as Struct
import Test.Binding.Combinators.Unlifted qualified as Unlifted

tests :: TestTree
tests = testGroup "Binding.Combinators"
    [ FirstBinding.tests
    , Inputs.tests
    , Scratch.tests
    , Outputs.tests
    , Auto.tests
    , Errors.tests
    , Closers.tests
    , Unlifted.tests
    , Struct.tests
    ]
