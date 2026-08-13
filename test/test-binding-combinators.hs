module Main (main) where

import Test.Tasty (defaultMain)

import Test.Binding.Combinators qualified as Combinators

main :: IO ()
main = defaultMain Combinators.tests
