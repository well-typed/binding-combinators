{-# LANGUAGE GADTs #-}

-- | The spec type itself, and the out-parameter values a spec collects.
--
-- Most bindings never import this module: t'ToHighLevel' and 'toHighLevel' are
-- re-exported from "Binding.Combinators", and the rest mostly surface in type
-- signatures and error messages. It is here so that those types are documented where
-- they are defined, and so that a
-- combinator of your own can name them.
module Binding.Combinators.Internal.Spec (
    -- * The spec
    ToHighLevel (..)
  , toHighLevel
    -- * The collected out-parameter values
  , Outputs (..)
  , AssembleOutputs
  , UncurryOutputs (..)
  ) where

import Data.Kind (Type)

{-------------------------------------------------------------------------------
  The collected out-parameter values
-------------------------------------------------------------------------------}

-- | The values that the @output@s in a spec read back, most recent first (each
-- @output@ prepends as the spec is read downward).
--
-- Only @output@ builds one, and only a closer takes one apart, so the reversed order
-- never escapes: 'AssembleOutputs' and 'uncurryOutputs' both undo it, and the assembler
-- you write takes its arguments in spec order.
type Outputs :: [Type] -> Type
data Outputs os where
  NoOutputs :: Outputs '[]
  (:*)      :: a -> Outputs os -> Outputs (a : os)
infixr 5 :*

-- | The type of the function a closer wants: one argument per output, in __spec
-- order__, and then @r@.
--
-- It is a fold over @os@ that hangs each output in front of @r@; because @os@ is
-- most-recent-first, the fold reverses it back into spec order:
--
-- > AssembleOutputs '[]         r  =                  r
-- > AssembleOutputs '[x]        r  =  x ->            r
-- > AssembleOutputs '[y, x]     r  =  x -> y ->       r
-- > AssembleOutputs '[z, y, x]  r  =  x -> y -> z ->  r
--
-- So for the spec
--
-- > output boolOut $ output textOut $ resultPure f
--
-- the collected @os@ is @\'[Text, Bool]@ and @f@ has to be a
-- @Bool -> Text -> CInt -> hs@: the two outputs in the order they appear, then the C
-- return value, then whatever result you want.
--
-- Note what @r@ absorbs: the whole @c -> hs@ tail (the @CInt -> hs@ of the example
-- above), rather than the high-level result type alone. That is why
-- 'Binding.Combinators.resultPure' can pass @'AssembleOutputs' os (c -> hs)@ and get an
-- assembler that ends in the C return value.
--
-- One practical consequence: the family reduces as soon as the /number/ of outputs is
-- known, whatever their types are. A closer's argument type is therefore concrete even
-- while an @output@ above it is still unwritten (a typed hole, @_@), which is what makes
-- @resultPure _@ report a usable type.
type AssembleOutputs :: [Type] -> Type -> Type
type family AssembleOutputs os r where
  AssembleOutputs '[]      r = r
  AssembleOutputs (a : os) r = AssembleOutputs os (a -> r)

-- | Apply an assembler to the collected values: __n-ary uncurrying__ over t'Outputs',
-- and a closer's last step. It is the reason 'Binding.Combinators.resultPure' and
-- 'Binding.Combinators.resultIO' carry an @UncurryOutputs os@ constraint. Any spec built
-- from the combinators satisfies it.
--
-- Where 'Prelude.uncurry' turns a two-argument function into one taking a pair, this
-- turns an @n@-argument assembler into one taking the @n@ collected outputs, for the
-- @n@ that @os@ records. The assembler comes first, as it does in 'Prelude.uncurry':
--
-- > uncurry      :: (a -> b -> c)        -> (a, b)     -> c
-- > uncurryOutputs :: AssembleOutputs os r -> Outputs os -> r
--
-- One place the analogy stops: t'Outputs' is most-recent-first while the assembler
-- takes its arguments in spec order, so this uncurries over the /reverse/ of @os@.
-- 'AssembleOutputs' folds in the same direction, which is what lines the two up.
class UncurryOutputs (os :: [Type]) where
  uncurryOutputs :: AssembleOutputs os r -> Outputs os -> r

instance UncurryOutputs '[] where
  uncurryOutputs f NoOutputs = f
  {-# INLINE uncurryOutputs #-}

instance UncurryOutputs os => UncurryOutputs (a : os) where
  uncurryOutputs f (x :* xs) = uncurryOutputs f xs x
  {-# INLINE uncurryOutputs #-}

{-------------------------------------------------------------------------------
  The spec
-------------------------------------------------------------------------------}

-- | A recipe for turning the low-level callable @lo@ into the high-level function
-- @hi@, collecting the out-parameter types @os@ on the way.
--
-- The three indices are described in \"Reading the signatures\" in
-- "Binding.Combinators"; in short, @lo@ is what is left of the C function's type,
-- @hi@ is what is left of the high-level one, and @os@ is the out-parameter Haskell
-- types collected /above/ this point, most recent first.
--
-- @os@ starts empty at 'toHighLevel' and each @output@ adds to it going down, so it is
-- known from the spec's own text: by the time the closer is reached it has the
-- complete list and can demand an @'AssembleOutputs' os@ for it. Nothing has to be
-- inferred backwards out of the closer, which is what keeps the design workable.
--
-- The value threaded alongside is the deferred read-back: an @'IO' ('Outputs' os)@
-- that each @output@ extends with its own peek and that a closer runs once the C call
-- has returned.
--
-- Build one with @input@ \/ @output@ \/ @scratch@ and a closer; see
-- "Binding.Combinators".
type ToHighLevel :: [Type] -> Type -> Type -> Type
newtype ToHighLevel os lo hi = ToHighLevel (IO (Outputs os) -> lo -> hi)

-- | Run a finished spec against a low-level callable (the raw @foreign import@) to
-- get the high-level function. Every binding ends here.
--
-- This is also where the two ends are tied down: @lo@ unifies with the C function's
-- actual type and @hi@ with the high-level type signature, and everything in the spec
-- between them follows from those two. A spec starts with nothing collected, hence
-- the @\'[]@.
--
-- The callable comes first so that the spec, which is the long part, can be chained
-- onto it with @($)@ and needs no parentheses of its own:
--
-- > hsStrncmp :: String -> ByteString -> IO Int
-- > hsStrncmp = toHighLevel c_strncmp
-- >           $ input  withCStringIn
-- >           $ input2 useAsByteStringLenIn
-- >           $ resultPure fromIntegral
--
-- __The high-level arguments arrive in C's order.__ Each @input@ adds its argument
-- where the C function takes it, so a point-free binding's signature follows the
-- prototype rather than your preference. That is why @hsStrncmp@ above is
-- @String -> ByteString -> IO Int@ and could not be written the other way round.
--
-- To expose a different order, name the arguments and apply them yourself, in the
-- order the spec consumes them:
--
-- > -- int crypto_sign_verify_detached(const unsigned char *sig, const unsigned char *m,
-- > --                                 unsigned long long mlen, const unsigned char *pk);
-- > verifyDetached :: PublicKey -> Signature -> ByteString -> Bool
-- > verifyDetached publicKey signature message =
-- >   toHighLevelPure crypto_sign_verify_detached spec signature message publicKey
-- >   --                          the spec's order, not the signature's ^
--
toHighLevel :: lo -> ToHighLevel '[] lo hi -> hi
toHighLevel lo (ToHighLevel f) = f (pure NoOutputs) lo
{-# INLINE toHighLevel #-}
