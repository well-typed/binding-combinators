-- | Lift a low-level FFI binding into a high-level Haskell wrapper.
--
-- A binding is a /spec/: one combinator per C argument, chained with @($)@ and closed
-- by a result converter, hung off the raw @foreign import@ with 'toHighLevel'.
--
-- > hsStrncmp :: String -> ByteString -> IO Int
-- > hsStrncmp = toHighLevel c_strncmp
-- >           $ input  withCStringIn        -- 1 C argument
-- >           $ input2 useAsByteStringLenIn -- 2 C arguments
-- >           $ resultPure fromIntegral
--
-- It reads top to bottom like an annotated copy of the C prototype, and each combinator
-- says what becomes of one C argument:
--
--   * 'input' takes one Haskell argument and marshals it in;
--   * 'output' allocates an out-parameter, whose value becomes part of the result;
--   * 'scratch', 'scratchArray' and 'fixed' fill a C argument the high-level type
--     never exposes;
--   * a closer ('resultPure', 'resultIO' and friends) turns the C return value, plus
--     any outputs, into the high-level result.
--
-- The closer's function is the /assembler/: it receives every 'output' value in spec
-- order, then the C return value, and decides the high-level result. So
-- @output a $ output b $ resultPure f@ calls @f@ with three arguments and returns
-- whatever @f@ returns, a tuple constructor, a wildcard to drop a value, or any other
-- function for the shape you want (see 'resultPure'). With no outputs the assembler is
-- the @c -> hs@ conversion alone.
--
-- Closers come in two kinds. The ones here take the assembler from you, as a function
-- ('resultPure', 'resultIO') or as a fixed policy ('discardResult', 'throwOnNonZero',
-- 'asResult'), with 'throwOn' to wrap any of them in a check.
-- "Binding.Combinators.Auto" has the ones that derive the assembler from the
-- high-level signature instead, and its module header tables the two sets against each
-- other. The fixed-policy closers here are all at @\'[]@, so a spec that has outputs
-- /and/ a status to check wants 'Binding.Combinators.Auto.checkedResult'.
--
-- A few other modules do the rest. "Binding.Combinators.Marshaller" is the vocabulary
-- for moving one value across the boundary, with ready-made marshallers in its
-- "Binding.Combinators.Marshaller.Utils" submodule. "Binding.Combinators.Defaults"
-- gives each Haskell type a default marshaller, and "Binding.Combinators.Auto" uses
-- those to write the ordinary combinators for you, reading them off the high-level type
-- signature.
--
module Binding.Combinators (
    -- * The ToHighLevel type
    ToHighLevel
  , toHighLevel
  , AssembleOutputs
  , UncurryOutputs
    -- | @ThreadIn hi@ appears in the signature of every combinator that fills a C
    -- argument. A spec never mentions it, since it is discharged by the high-level
    -- type; a combinator of your own that is polymorphic in @hi@ has to carry it in
    -- its context, which is why it is exported here. Its method lives in
    -- "Binding.Combinators.Internal.Threading".
  , ThreadIn
    -- ** Reading the signatures
    -- $signatures
    -- * Building a wrapper
  , input
  , input2
  , input3
  , inputN
  , output
  , scratch
  , scratchArray
  , fixed
  , resultPure
  , resultIO
  , discardResult
    -- ** Building against typed holes
    -- $holes
    -- ** Reading the type errors
    -- $errors
    -- * Dropping a struct marshaller into a spec
  , asArgument
  , asArgumentC
  , asOutput
  , asResult
    -- ** A worked struct example
    -- $structs
    -- * Error-aware combinators
  , throwOn
  , throwOnNonZero
  , throwUnlessZero
  , throwOnOut
    -- * Exposing a deterministic call as pure
    --
    -- | 'toHighLevelPure' runs a spec the way 'toHighLevel' does, but hands back the
    -- wrapper with the @IO@ taken off. See "Binding.Combinators.Result".
  , toHighLevelPure
  , Unpurify
  , Purifiable
    -- * Writing a combinator of your own
    -- $writing
  ) where

import Control.Exception (Exception, throwIO)
import Control.Monad ((>=>))
import Data.Proxy (Proxy (Proxy))
import Foreign.Marshal.Alloc (allocaBytesAligned)
import Foreign.Marshal.Array (allocaArray)
import Foreign.Ptr (Ptr)
import Foreign.Storable (Storable)
import GHC.Exts (TYPE)

import HsBindgen.Runtime.Marshal (ReadRaw, StaticSize, WriteRaw, readRaw,
                                  staticAlignment, staticSizeOf)
import HsBindgen.Runtime.PtrConst (PtrConst)

import Binding.Combinators.Internal.Spec (AssembleOutputs, Outputs (..),
                                          ToHighLevel (..), UncurryOutputs (..),
                                          toHighLevel)
import Binding.Combinators.Internal.Threading (ThreadIn (..))
import Binding.Combinators.Marshaller (Marshal (..), MarshalStruct,
                                       UnmarshalStruct (..), Unmarshaller (..),
                                       asConstArg, runUnmarshalStruct,
                                       unmarshalOut, unmarshalOutWith,
                                       withStruct)
import Binding.Combinators.Result (Purifiable, Unpurify, toHighLevelPure)

{-------------------------------------------------------------------------------
  Building a wrapper
-------------------------------------------------------------------------------}

-- | Add one input at the head of the spec, filling exactly one C argument. The
-- high-level type gains one argument @hs@, in the position C takes it:
--
-- > -- int strncmp(const char *s1, const char *s2, size_t n);
-- > hsStrncmp :: String -> ByteString -> IO Int
-- > hsStrncmp = toHighLevel c_strncmp
-- >           $ input  withCStringIn        -- const char *s1
-- >           $ input2 useAsByteStringLenIn -- s2, n
-- >           $ resultPure fromIntegral
--
-- Most marshallers fill one C argument. For two or three use 'input2' \/ 'input3';
-- for any other arity, 'inputN', whose entry says why the fixed-arity forms are the
-- ones to reach for while a spec is still being written.
--
-- The @'TYPE' rep@ in the signature is there so an /unlifted/ by-value argument goes
-- through 'input' like any other (see
-- 'Binding.Combinators.Unlifted.bracketUnlifted'). For an ordinary C type, ignore it.
input
  :: forall {rep} (c :: TYPE rep) hs lo' hi os.
    ThreadIn hi
  => Marshal hs (c -> lo') lo'
  -> ToHighLevel os lo' hi
  -> ToHighLevel os (c -> lo') (hs -> hi)
input = inputN
{-# INLINE input #-}

-- | 'input' for a marshaller that fills exactly two C arguments (the @(const char *,
-- size_t)@ shape of @useAsByteStringLenIn@, say). See 'input' for why the fixed arity
-- helps inference and typed holes.
--
input2
  :: ThreadIn hi
  => Marshal hs (c1 -> c2 -> lo') lo'
  -> ToHighLevel os lo' hi
  -> ToHighLevel os (c1 -> c2 -> lo') (hs -> hi)
input2 = inputN
{-# INLINE input2 #-}

-- | 'input' for a marshaller that fills exactly three C arguments (a matrix as
-- @(rows, cols, data)@, say). See 'input' for why the fixed arity helps inference
-- and typed holes.
--
input3
  :: ThreadIn hi
  => Marshal hs (c1 -> c2 -> c3 -> lo') lo'
  -> ToHighLevel os lo' hi
  -> ToHighLevel os (c1 -> c2 -> c3 -> lo') (hs -> hi)
input3 = inputN
{-# INLINE input3 #-}

-- | 'input' for a marshaller of /any/ arity, which is all a finished spec needs, and
-- what the other three are defined as. A finished spec reads the same either way.
--
-- While a spec is still being written, prefer 'input' \/ 'input2' \/ 'input3'. They
-- pin how much of @lo@ is consumed from their own type, so @input _@ reports a fully
-- determined marshaller, and GHC can offer the matching one as a valid hole fit, even
-- when the tail below is an @auto@ stub. @inputN _@ under that same stub comes back
-- with its residual @lo'@ ambiguous. See \"Building against typed holes\" below.
--
inputN
  :: ThreadIn hi
  => Marshal hs lo lo'
  -> ToHighLevel os lo' hi
  -> ToHighLevel os lo (hs -> hi)
inputN (Marshal run) (ToHighLevel rest) =
  ToHighLevel $ \pending lo hs -> threadIn (run hs lo) (rest pending)
{-# INLINE inputN #-}

-- | Add one output at the head of the spec. The high-level type gains no argument; the
-- output's slot is allocated on the way in, its Haskell type joins the spec's output
-- list @os@, and its value becomes one more argument to the closer's assembler, in spec
-- order and ahead of the C return value (see the module header and 'resultPure' for how
-- the assembler consumes them).
--
-- For an /unlifted/ by-value out-parameter (a @W@ struct buffer) see
-- 'Binding.Combinators.Unlifted.outputUnlifted'.
--
output
  :: ThreadIn hi
  => Unmarshaller c hs
  -> ToHighLevel (hs : os) lo'        hi
  -> ToHighLevel os        (c -> lo') hi
-- The applicative order here matters: @pending@ runs first, so
-- the read-backs happen in spec order. Writing it the shorter way round,
-- @(:*) <$> readBack c <*> pending@, builds the same 'Outputs' but runs the reads
-- bottom-up, which matters as soon as one of them frees or throws.
output (Unmarshaller allocate readBack) (ToHighLevel rest) =
  ToHighLevel $ \pending lo ->
    threadIn (\k -> allocate (\c ->
               k ( flip (:*) <$> pending <*> readBack c
                 , lo c
                 )
                        )
             )
             (uncurry rest)
{-# INLINE output #-}

-- | Add a scratch combinator: a bracket supplying one C argument the call writes
-- into and the caller never sees. It contributes nothing to the high-level type,
-- neither an argument nor a result component.
--
-- Most callers want 'scratchArray', which is this over
-- 'Foreign.Marshal.Array.allocaArray'. To hand in a buffer you already have rather
-- than allocating one here, use 'fixed', which pins any value into a C argument.
--
scratch
  :: ThreadIn hi
  => (forall r. (c -> IO r) -> IO r)
  -> ToHighLevel os lo' hi
  -> ToHighLevel os (c -> lo') hi
scratch br (ToHighLevel rest) =
  ToHighLevel $ \pending lo ->
    threadIn (\k -> br (\c -> k (lo c)))
             (rest pending)
{-# INLINE scratch #-}

-- | Allocate an @n@-element array of @a@ as a scratch C argument the call writes
-- into and the caller never sees. @'scratchArray' n = 'scratch' ('allocaArray' n)@.
--
scratchArray
  :: ( Storable a
     , ThreadIn hi
     )
  => Int -> ToHighLevel os lo' hi -> ToHighLevel os (Ptr a -> lo') hi
scratchArray n = scratch (allocaArray n)
{-# INLINE scratchArray #-}

-- | Supply a constant (or otherwise fixed) C argument the high-level type does not
-- expose: a flags word, a NULL callback, a context handle, a length the binding
-- already knows. Where 'scratch' allocates something for the duration of the call, 'fixed'
-- pins a value you already have:
--
-- > -- void randombytes_buf(void *buf, size_t size);
-- > randomBytes :: Int -> IO ByteString
-- > randomBytes n = toHighLevel randombytes_buf
-- >               $ output (byteStringOut n) -- void *buf: the bytes we keep
-- >               $ fixed  (fromIntegral n)  -- size_t size: not a high-level argument
-- >               $ autoResult
--
-- @fixed c = 'scratch' (\\k -> k c)@, so the two are the same combinator; pick
-- whichever names what you are doing.
--
fixed
  :: ThreadIn hi
  => c -> ToHighLevel os lo' hi -> ToHighLevel os (c -> lo') hi
fixed c = scratch (\k -> k c)
{-# INLINE fixed #-}

-- | Close the spec with a pure assembler: it receives each 'output' value in spec
-- order, then the C return value, and returns the high-level result. Its type is
-- spelled out by 'AssembleOutputs', so GHC reports it concretely in a hole.
--
-- With no outputs this is the @c -> hs@ conversion alone, exactly as it reads:
-- @resultPure fromIntegral@, or @resultPure (== 0)@ to close an @int@ to a 'Bool'.
-- With outputs it gains one argument per output:
--
-- > output a $ output b $ resultPure (,,)               -- IO (a, b, c), a flat tuple
-- > output a $ output b $ resultPure (\x y _ -> (x, y)) -- IO (a, b), C return dropped
--
resultPure
  :: UncurryOutputs os
  => AssembleOutputs os (c -> hs)
  -> ToHighLevel os (IO c) (IO hs)
resultPure f = ToHighLevel $ \pending cFn -> do
    c    <- cFn
    outs <- pending
    pure (uncurryOutputs f outs c)
{-# INLINE resultPure #-}

-- | 'resultPure' for an assembler that ends in 'IO': for a conversion that copies
-- out memory, frees a pointer, or throws. Since it sees the outputs and the C
-- return together, a status check and the result it guards live in one function:
--
-- > output namesOut $ fixed errbuf $ resultIO (\names status -> do
-- >   when (status /= 0) $ throwIO . PcapError =<< peekCString errbuf
-- >   pure names)
--
resultIO
  :: UncurryOutputs os
  => AssembleOutputs os (c -> IO hs)
  -> ToHighLevel os (IO c) (IO hs)
resultIO f = ToHighLevel $ \pending cFn -> do
    c    <- cFn
    outs <- pending
    uncurryOutputs f outs c
{-# INLINE resultIO #-}

-- | Close a spec that has no outputs, discarding the C return value; the result is
-- @()@.
--
discardResult :: ToHighLevel '[] (IO c) (IO ())
discardResult = resultPure (const ())
{-# INLINE discardResult #-}

{-------------------------------------------------------------------------------
  Dropping a struct marshaller into a spec
-------------------------------------------------------------------------------}

-- | Drop a t'MarshalStruct' into an 'input': the high-level type gains one argument
-- and the C call receives a @'Ptr' s@. The struct is written into a zeroed slot
-- (see 'withStruct'), so padding reaches C as zeros.
--
asArgument
  :: ( StaticSize s
     , WriteRaw s
     )
  => MarshalStruct hi s
  -> Marshal hi (Ptr s -> lo') lo'
asArgument sm =
  Marshal $ \hi lo k -> withStruct sm hi (\p -> k (lo p))
{-# INLINE asArgument #-}

-- | Drop a t'MarshalStruct' into a @const T *@ argument, the @const@ form of
-- 'asArgument': it fills a non-@const@ @'Ptr' s@ and 'asConstArg' retags it @const@,
-- so one struct marshaller serves a C argument typed @const T *@.
--
asArgumentC
  :: ( StaticSize s
     , WriteRaw s
     )
  => MarshalStruct hi s
  -> Marshal hi (PtrConst s -> lo') lo'
asArgumentC = asConstArg . asArgument
{-# INLINE asArgumentC #-}

-- | Drop an t'UnmarshalStruct' into an 'output': allocate a @'Ptr' struct@ for
-- the call to fill, then read the high-level value back. It frees no heap the
-- struct's fields point to, so a C-allocated pointer field must be freed by
-- the t'UnmarshalStruct' (copy, then free, inside @unmarshalField@). The slot is
-- uninitialized, unlike the zeroed slot of 'asArgument', so C must fill
-- every field the t'UnmarshalStruct' reads.
--
asOutput
  :: forall struct hi.
    ( StaticSize struct
    , ReadRaw struct
    )
  => UnmarshalStruct struct hi
  -> Unmarshaller (Ptr struct) hi
asOutput sm = unmarshalOutWith allocStruct (readRaw >=> runUnmarshalStruct sm)
  where
    allocStruct :: (Ptr struct -> IO r) -> IO r
    allocStruct =
      allocaBytesAligned (staticSizeOf (Proxy @struct)) (staticAlignment (Proxy @struct))
{-# INLINE asOutput #-}

-- | Close a spec whose C call returns the low-level struct by value: read the
-- high-level value out of the returned struct.
--
asResult :: UnmarshalStruct struct hi -> ToHighLevel '[] (IO struct) (IO hi)
asResult sm = resultIO (runUnmarshalStruct sm)
{-# INLINE asResult #-}

{-------------------------------------------------------------------------------
  Error-aware combinators

  Every combinator runs in 'IO', so a check can sit wherever the error signal lives,
  and a throw unwinds every bracket opened before it. 'throwOnNonZero' is a closer,
  'throwOn' wraps an existing closer, and 'throwOnOut' is an output marshaller.
-------------------------------------------------------------------------------}

-- | Wrap a result closer with an error check: run it, then classify the converted
-- value. 'Left' throws, 'Right' yields the refined value. The check sees the
-- converted value (@throwOn check ('resultPure' 'fromIntegral')@ classifies the
-- 'Int', not the raw 'Foreign.C.Types.CInt') and may change the result type.
--
throwOn
  :: Exception e
  => (hs -> Either e hs')
  -> ToHighLevel os (IO c) (IO hs)
  -> ToHighLevel os (IO c) (IO hs')
throwOn classify (ToHighLevel close) = ToHighLevel $ \pending cFn -> do
  hs <- close pending cFn
  either throwIO pure (classify hs)
{-# INLINE throwOn #-}

-- | Close an __output-free__ spec, throwing when the C status code is non-zero; the
-- result is @()@.
--
-- For a spec that has outputs, reach for 'Binding.Combinators.Auto.checkedResult',
-- which runs the same kind of check at any number of them. The difference between the
-- two is where the outputs go, not what the check does, so the choice is made by the
-- spec above the closer rather than by the C function's status convention.
--
-- Use 'resultIO' instead where the status also /decides/ the result rather than only
-- guarding it, since its assembler sees the status and the outputs together.
--
throwOnNonZero
  :: ( Eq c
     , Num c
     , Exception e
     )
  => (c -> e)
  -> ToHighLevel '[] (IO c) (IO ())
throwOnNonZero mk = resultIO (throwUnlessZero mk)
{-# INLINE throwOnNonZero #-}

-- | The check 'throwOnNonZero' performs, on its own: zero passes, anything else
-- throws @mk c@.
--
-- This is the same policy in the shape 'Binding.Combinators.Auto.checkedResult' and
-- 'Binding.Combinators.Auto.autoChecked' expect, so a spec /with/ outputs can name it
-- rather than writing the @if@ out per call:
--
-- > encrypt = toHighLevel crypto_secretbox_easy
-- >         $ output ciphertextOut
-- >         $ autoChecked (throwUnlessZero (SodiumError "crypto_secretbox_easy"))
--
-- For a status that is not zero-is-success, or one whose failure detail needs
-- 'IO' to fetch, write the check yourself: it is an ordinary @c -> 'IO' ()@.
--
throwUnlessZero
  :: ( Eq c
     , Num c
     , Exception e
     )
  => (c -> e)                   -- ^ build the exception from the rejected status
  -> c
  -> IO ()
throwUnlessZero mk c = if c == 0 then pure () else throwIO (mk c)
{-# INLINE throwUnlessZero #-}

-- | An error-aware output: peek the C value, classify it, throw on 'Left',
-- otherwise keep the refined value. For out-parameters that signal failure
-- themselves (a NULL out-pointer, an errcode in the slot).
--
throwOnOut
  :: (Storable c, Exception e)
  => (c -> Either e hs)
  -> Unmarshaller (Ptr c) hs
throwOnOut classify = unmarshalOut (either throwIO pure . classify)
{-# INLINE throwOnOut #-}

{-------------------------------------------------------------------------------
  Haddock named sections
-------------------------------------------------------------------------------}

-- $signatures
-- A mistake in a spec surfaces as a type error against these signatures, so knowing
-- how to read them is how you find the combinator that went wrong.
--
-- It is all one type, @t'ToHighLevel' os lo hi@, with three indices:
--
-- [@lo@]: what is left of the __low-level function signature__. At the top of a spec this is the whole
--   thing; each combinator removes the C arguments it fills. A primed @lo'@ in a
--   combinator's type always means \"what is left below this one\".
--
-- [@hi@]: what is left of the __high-level function signature__. 'input' removes one
--   argument from the front of it. 'output' and 'scratch' remove none, because they
--   add no high-level argument.
--
-- [@os@]: the __outputs collected so far__, a type-level list of the (output) Haskell types,
--   most recent first. Empty at the top, one longer after each 'output'. The closer
--   sees the finished list and asks for an 'AssembleOutputs' over it, with the companion
--   'UncurryOutputs' feeding it the collected values. Nothing you write compensates for
--   that order: those two undo it between them, so the assembler takes its arguments in
--   spec order. It matters only when reading @os@ off a type error.
--
-- Everything else names a single value at a single combinator: @hs@ a Haskell one, @c@
-- a C one.
--
-- A spec unifies because every combinator relates the spec /below/ it, which is its
-- argument, to the spec /at/ it, which is its result. Line the two up:
--
-- > input  :: Marshal hs (c -> lo') lo'
-- >        -> ToHighLevel os lo'        hi         -- the rest of the spec
-- >        -> ToHighLevel os (c -> lo') (hs -> hi) -- this one and everything below
--
-- Going down the chain @lo@ loses a C argument and @hi@ loses a high-level argument, in
-- step. 'output' has the same shape with the roles moved around:
--
-- > output :: Unmarshaller c hs
-- >        -> ToHighLevel (hs : os) lo'        hi -- one more output below here
-- >        -> ToHighLevel os        (c -> lo') hi -- and nothing added to hi
--
-- And 'toHighLevel' pins both ends at once:
--
-- > toHighLevel :: lo -> ToHighLevel '[] lo hi -> hi
--
-- @lo@ unifies with the C function's actual type, @hi@ with the high-level type
-- signature. GHC has nothing left to guess, which is why holes come back concrete and
-- why @auto@ can work at all.
--
-- Two consequences matter when an error does appear. A spec is checked as a whole, so
-- one wrong combinator often surfaces as a mismatch reported at a neighbouring one:
-- compare the @lo@ in the message against the C prototype to find where the two
-- stopped lining up. And a binding with /no/ type signature leaves @hi@ open, so
-- nothing is forced and the errors get much worse. Write the signature first.
--

-- $writing
-- Enough context to write your own combinators. The full derivation, combinator by
-- combinator, is in @docs\/how-it-works.md@, and @docs\/writing-a-combinator.md@
-- builds one end to end over libgit2's constructors.
--
-- A combinator runs at /spec-construction time/, before the wrapper has received
-- its arguments and before C has run. So it cannot call @alloca@ and it cannot
-- 'Foreign.Storable.peek'. Two mechanisms carry everything that follows from that.
--
-- __Brackets are deferred.__ 'Binding.Combinators.Internal.Threading.threadIn'
-- pushes a bracket past the arguments still to come, opening it at the @IO@ at the
-- end of @hi@. Nesting opens the brackets outermost first and closes them in
-- reverse, so a throw anywhere inside unwinds all of them. 'input' and 'scratch'
-- are each one call to it.
--
-- __Read-backs are deferred.__ 'output' allocates its slot but cannot read it, so
-- it builds the read as an action and adds it to the spec's pending read-backs. A
-- closer runs them after the call, which is why a closer that rejects the C return
-- value (see 'Binding.Combinators.Auto.checkedResult') never reads an
-- out-parameter C did not fill.
--
-- The @os@ index records what those pending read-backs will produce, most recent
-- first, so a closer's assembler type is fully determined by the combinators above
-- it. Nothing is inferred backwards.
--

-- $holes
-- The library is designed so typed holes can guide how you write a spec. Write the
-- high-level type signature first, then fill the spec one combinator at a time, holding
-- a hole @_@ at the combinator you are working on and __stubbing the tail with @auto@__.
--
-- The signature is what makes this work: everything the combinators need flows
-- downwards from it and from the C function's type, so with the tail in place GHC
-- reports each hole concretely. Use @auto@ as the stub because it type-checks against
-- any remaining spec while still carrying that information;
-- 'Binding.Combinators.Auto.autoResult' does the same for the closer alone.
--
-- Take @parse_int :: PtrConst CChar -> Ptr CInt -> IO CInt@ and a target
-- @hsParseInt :: String -> IO (Int, Int)@:
--
-- > hsParseInt = toHighLevel parse_int
-- >            $ input _
-- >            $ output peekIntOut
-- >            $ auto
-- >   -- Found hole: _ :: Marshal String (PtrConst CChar -> Ptr CInt -> IO CInt) (Ptr CInt -> IO CInt)
-- >   --   Valid hole fits include withCStringIn, defaultIn
-- >
-- > hsParseInt = toHighLevel parse_int
-- >            $ input withCStringIn
-- >            $ output _
-- >            $ auto
-- >   -- Found hole: _ :: Unmarshaller (Ptr CInt) Int
--
-- The output's Haskell type is concrete because the high-level result type
-- determines it. If @auto@\'s assembly is not the shape you want, swap it for a
-- closer and GHC hands you the assembler:
--
-- > hsParseInt = toHighLevel parse_int
-- >            $ input withCStringIn
-- >            $ output peekIntOut
-- >            $ resultPure _
-- >   -- Found hole: _ :: Int -> CInt -> (Int, Int)
--
-- One argument per 'output' in spec order, then the C return value.
--
-- @autoInputs@ works the same way, and is often the more comfortable stub of the two
-- because it leaves the hole where the decision actually is. Against
-- @c_strncmp :: Ptr CChar -> Ptr CChar -> CSize -> IO CInt@ and a signature returning
-- 'Bool', a hole in the closer comes back fully applied:
--
-- > hs1 :: Ptr CChar -> Ptr CChar -> CSize -> IO Bool
-- > hs1 = toHighLevel c_strncmp (autoInputs $ resultPure _)
-- >   -- Found hole: _ :: CInt -> Bool
--
-- and a hole in place of the whole tail reports the spec still to be written, which
-- names all three indices at once:
--
-- > hs2 = toHighLevel c_strncmp (autoInputs _)
-- >   -- Found hole: _ :: ToHighLevel '[] (IO CInt) (IO Bool)
--
-- Read that as: nothing collected yet, @IO CInt@ left of the C function, @IO Bool@
-- wanted. When C still has an out-parameter to give, it shows up in the same place, so
-- against @c_frexp :: CDouble -> Ptr CInt -> IO CDouble@ and
-- @hs4 :: Double -> IO (Int, Double)@:
--
-- > hs4 = toHighLevel c_frexp (autoInputs _)
-- >   -- Found hole: _ :: ToHighLevel '[] (Ptr CInt -> IO CDouble) (IO (Int, Double))
-- >
-- > hs4 = toHighLevel c_frexp (autoInputs $ output _ $ autoResult)
-- >   -- Found hole: _ :: Unmarshaller (Ptr CInt) Int
--
-- The @Ptr CInt ->@ still sitting in the first message is the combinator you have not
-- written yet, and the second shows what filling it asks for.
--
-- Two things weaken a hole. @undefined@ as the tail stub constrains nothing, so
-- @output _ $ undefined@ comes back with its value type ambiguous; use @auto@.
--
-- And pair @auto@ with 'input' \/ 'input2' \/ 'input3' rather than 'inputN'. Against a
-- /finished/ tail @inputN _@ is perfectly well determined, because the rest of the
-- chain says where the C arguments stop. But @auto@ is polymorphic in the C type it
-- consumes, which is what makes it a good stub in the first place, so it cannot supply
-- that information: @inputN _ $ auto@ comes back @Marshal String (...) lo\'@ with
-- @lo\'@ ambiguous. The fixed-arity forms pin the residual themselves and so compose
-- with @auto@.
--

-- $errors
-- The combinators lean on the type checker, so a spec that does not line up shows
-- up as a type error rather than a runtime failure. These are the ones that come up
-- often, each with a short fix.
--
-- @No default input marshaller for type ...@ (or @output@ \/ @result@) means @auto@,
-- or an explicit 'Binding.Combinators.Defaults.defaultIn' \/ @defaultOut@ \/
-- @defaultRes@, met a type with no default. Pass an explicit marshaller to that
-- combinator, or give the type its own default in one instance (see
-- 'Binding.Combinators.Defaults.DefaultIn').
--
-- @auto cannot line the high-level type up with the C function@ means @auto@ ran
-- out of high-level arguments while C still expects one. That leftover C argument
-- is one the high-level type does not expose: give it an explicit 'output' or
-- 'scratch', or add the missing argument to the signature. @auto@ fills inputs and the
-- result, nothing else.
--
-- @auto cannot assemble this result@ means @auto@ reached the closing combinator but
-- the outputs it collected and the C return do not add up to the result type in the
-- signature. The message lists all three. Either give the signature that result type,
-- or close by hand with 'resultPure' \/ 'resultIO', which take an assembler of the
-- same arity and may return anything.
--
-- @auto cannot assemble this result from the out-parameters alone@ is the same
-- complaint where nothing of the C return survived: the call returns @void@, or a
-- closer such as 'Binding.Combinators.Auto.checkedResult' consumed its status. The
-- message therefore lists two types rather than three, and the result wanted is one
-- component short of what it would otherwise be.
--
-- An ambiguous result type usually means the closer default has nothing to resolve
-- against: 'Binding.Combinators.Defaults.defaultRes' reads the result off
-- the signature, so a binding written without a result annotation cannot pick one.
-- Give every binding a type signature.
--
-- A wrong assembler is reported against 'AssembleOutputs', which GHC prints unreduced:
--
-- > Expected: AssembleOutputs '[Int, Int] (CInt -> Pair)
-- >   Actual: Int -> Int -> Pair
--
-- Read the expected type as \"one argument per output, then @CInt -> Pair@\", so
-- here the assembler is one argument short. GHC also appends a
-- @but its type ... has none@ clause counting the arrows it can see in the
-- unreduced application; ignore it, and compare the two types instead. The list is
-- the collected outputs __most recent first__, the reverse of the order the
-- assembler takes them in.
--

-- $structs
-- A C struct crosses the boundary in two halves: a t'MarshalStruct' that writes a
-- high-level value into the C layout, and an t'UnmarshalStruct' that reads one back.
-- Build each from the "Binding.Combinators.Marshaller" vocabulary, then drop it into a
-- spec with 'asArgument' (by-value argument), 'asArgumentC' (the @const T *@ form),
-- 'asOutput' (out-parameter), or 'asResult' (by-value return).
--
-- Two differences between the adapters are worth knowing before you pick one.
-- 'asArgument' writes into a fresh /zeroed/ slot, so padding reaches C as zeros, and
-- holds the field brackets open across the call. 'asOutput' allocates an
-- /uninitialized/ slot, so C must fill every field the t'UnmarshalStruct' reads, and it
-- frees nothing the fields point at.
--
-- @docs\/writing-a-struct-marshaller.md@ works a nested example through both sides end
-- to end, with the imports.
