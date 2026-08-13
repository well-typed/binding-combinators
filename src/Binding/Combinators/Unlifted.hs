-- | Supplying and reading /unlifted/, by-value C values through the @ToHighLevel@
-- combinators.
--
-- Some C APIs pass small structs /by value/. GHC's FFI cannot, so a binding holds the
-- struct's raw bytes as an /unlifted boxed/ value instead: an @R@ (a read-only byte
-- array) for an argument, a @W@ (a mutable byte array) for an out-parameter.
--
-- Most of the vocabulary takes @R@ and @W@ unchanged. An @R@ argument in particular
-- needs no new combinator: build the marshaller with the t'Marshal' constructor, or
-- with 'bracketUnlifted' here, and drop it into 'Binding.Combinators.input' as usual.
-- The one genuinely new combinator is 'outputUnlifted', for a @W@ out-parameter.
--
-- Both take any bracket of the right shape, so neither depends on where @R@ and @W@
-- come from. The @libclang-ffi@ example under @examples\/@ runs them against a real C
-- API that passes structs by value.
module Binding.Combinators.Unlifted (
    outputUnlifted
  , bracketUnlifted
  ) where

import GHC.Exts (UnliftedType)

import Binding.Combinators.Internal.Spec (Outputs (..), ToHighLevel (..))
import Binding.Combinators.Internal.Threading (ThreadIn (..))
import Binding.Combinators.Marshaller (Marshal (..), Unmarshaller (..))

-- | 'Binding.Combinators.output' for an /unlifted/ out-parameter: a by-value
-- struct written into a @W@ buffer ('UnliftedType'), the read-back done by an
-- t'Unmarshaller' built over e.g. @Clang.Internal.ByValue.preallocate@. One
-- 'outputUnlifted' covers every @W@ struct.
--
-- It behaves exactly like 'Binding.Combinators.output' in a spec, with no
-- tail-position restriction: the unlifted value is only ever captured in a closure,
-- never bound by representation-polymorphic code, so high-level arguments and further
-- outputs may follow an unlifted output.
--
outputUnlifted
  :: forall (c :: UnliftedType) hs lo' hi os.
     ThreadIn hi
  => Unmarshaller c hs
  -> ToHighLevel (hs : os) lo'        hi
  -> ToHighLevel os        (c -> lo') hi
outputUnlifted (Unmarshaller allocate readBack) (ToHighLevel rest) =
  ToHighLevel $ \pending lo ->
    -- 'pending' before 'readBack', as in 'Binding.Combinators.output': spec order.
    threadIn (\k -> allocate (\c -> k (lo c, (\outs v -> v :* outs) <$> pending <*> readBack c)))
             (\(loRest, pending') -> rest pending' loRest)
{-# INLINE outputUnlifted #-}

-- | 'Binding.Combinators.Marshaller.bracket' for an /unlifted/ C argument: a by-value
-- struct payload passed as an @R@ ('UnliftedType'). One 'bracketUnlifted' covers every
-- @R@ struct. The bracket supplies the value with e.g.
-- @Clang.Internal.ByValue.onHaskellHeap@, and the marshaller drops into
-- 'Binding.Combinators.input' unchanged.
--
bracketUnlifted
  :: forall (c :: UnliftedType) hs lo'.
     (forall r. hs -> (c -> IO r) -> IO r)
  -> Marshal hs (c -> lo') lo'
bracketUnlifted br = Marshal $ \hs lo k -> br hs (\c -> k (lo c))
{-# INLINE bracketUnlifted #-}
