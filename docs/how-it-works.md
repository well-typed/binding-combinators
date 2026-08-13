# How it works

A spec is a function that takes a low-level type and turns it into a
high-level type. Every combinator is also a function that takes a spec and
returns a slightly different one.

## The spec type

```haskell
data Outputs os where
  NoOutputs :: Outputs '[]
  (:*)      :: a -> Outputs os -> Outputs (a : os)

newtype ToHighLevel os lo hi = ToHighLevel (IO (Outputs os) -> lo -> hi)

toHighLevel :: lo -> ToHighLevel '[] lo hi -> hi
toHighLevel lo (ToHighLevel f) = f (pure NoOutputs) lo
```

## The three type arguments

`lo` is the low-level C signature. `hi` is the high-level Haskell signature. `os`
is the list of out-parameter types collected so far, most recent first.

A hole shows all three at once, which is why the typed-hole workflow is one of
the suggested ways to play with `binding-combinators`:

```haskell
c_strncmp :: PtrConst CChar -> PtrConst CChar -> CSize -> IO CInt

hsStrncmp :: String -> ByteString -> IO Int
hsStrncmp = toHighLevel c_strncmp _

-- Found hole:
--        _ :: ToHighLevel
--               '[]
--               (PtrConst CChar -> PtrConst CChar -> CSize -> IO CInt)
--               (String -> ByteString -> IO Int)
```

Going down a chain of combinator applications, `lo` loses C arguments, `hi`
gains Haskell arguments, and `os` grows with each `output`.

## Marshalling types

```haskell
newtype Marshal hs lo lo' =
  Marshal (forall r. hs -> lo -> (lo' -> IO r) -> IO r)
```

Read `lo` and `lo'` as the low-level function before and after this marshaller has
supplied its arguments. The number of arrows between them is how many C arguments
the marshaller fills:

```haskell
withCStringIn        :: Marshal String     (PtrConst CChar          -> lo') lo'
useAsByteStringLenIn :: Marshal ByteString (PtrConst CChar -> CSize -> lo') lo'
```

## Unmarshalling types

```haskell
data Unmarshaller c hs =
    Unmarshaller
      (forall r. (c -> IO r) -> IO r) -- allocate the slot
      (c -> IO hs)                    -- read it back, after the call
```

The two halves run at different times, which is the reason why `Unmarshaller` is a
pair of functions: the slot is allocated before the C call and read
after it. The read-back values collect in `Outputs`.

## Threading the brackets past the arguments

Take `strncmp`. By hand, two brackets stay open across the call:

```haskell
hsStrncmp s bs =
  withCString s        $ \pa ->      -- bracket 1
    useAsCStringLen bs $ \(pb, n) -> -- bracket 2
      fromIntegral <$>
        c_strncmp (constPtr pa) (constPtr pb) (fromIntegral n)
```

A spec has to be able to produce that nesting, but the wrapper's arguments
arrive one at a time, so the bracket cannot open where the combinator sits. It
has to be pushed past every argument still to come:

```haskell
class ThreadIn hi where
  threadIn :: (forall r. (a -> IO r) -> IO r) -- a bracket supplying an `a`
           -> (a -> hi)                       -- build hi, given that `a`
           -> hi

instance ThreadIn (IO r) where
  threadIn br f = br f

instance ThreadIn rest => ThreadIn (arg -> rest) where
  threadIn br f = \arg -> threadIn br (\a -> f a arg)
```

The instances walk `hi`'s arrows and open the bracket at the `IO` at the end.
Another way to interpret `threadIn` is that it will introduce all the
necessary lambda's, pushing the bracket to the `IO` call:

```haskell
threadIn br f                           -- hi = Int -> Bool -> IO r
  = \i   -> threadIn br (\a -> f a i)   -- hi = Bool -> IO r
  = \i b -> threadIn br (\a -> f a i b) -- hi = IO r
  = \i b -> br          (\a -> f a i b) -- open the bracket
```

Nesting opens them outermost first and closes them in reverse, so a throw
anywhere inside unwinds all of them.

## How do the combinators work

`input` consumes one C argument (on the `lo`w-level site) and adds one Haskell
argument (on the `hi`gh-level site). The marshaller is the bracket, and
`threadIn` holds it open until the call:

```haskell
input
  :: ThreadIn hi
  => Marshal hs (c -> lo') lo'
  -> ToHighLevel os lo'        hi
  -> ToHighLevel os (c -> lo') (hs -> hi)
input = inputN

inputN (Marshal run) (ToHighLevel rest) =
  ToHighLevel $ \pending lo hs ->
    threadIn (run hs lo) (rest pending)
```

`scratch` fills a C argument that the caller never sees because none is
introduced on the high-level, Haskell site. `lo` loses an argument while `hi`
and `os` are unchanged:

```haskell
scratch
  :: ThreadIn hi
  => (forall r. (c -> IO r) -> IO r)
  -> ToHighLevel os lo' hi
  -> ToHighLevel os (c -> lo') hi
scratch br (ToHighLevel rest) =
  ToHighLevel $ \pending lo ->
    threadIn (\k -> br (\c -> k (lo c)))
             (rest pending)
```

`fixed c` is `scratch (\k -> k c)`.

`output` loses the output parameter from `lo` and adds the read-back type to
the `os` type level list. The value does not come back as an argument; it is
collected for the closer:

```haskell
output
  :: ThreadIn hi
  => Unmarshaller c hs
  -> ToHighLevel (hs : os) lo'        hi
  -> ToHighLevel os        (c -> lo') hi
output (Unmarshaller allocate readBack) (ToHighLevel rest) =
  ToHighLevel $ \pending lo ->
    threadIn (\k -> allocate (\c ->
               k ( flip (:*) <$> pending <*> readBack c
                 , lo c
                 )))
             (uncurry rest)
```

`pending` comes first in that applicative, which is what makes the read-backs run
in spec order. The shorter `(:*) <$> readBack c <*> pending` builds the same
`Outputs` but reads bottom-up, and this matters as a read-back frees or throws.

## The closers

A closer receives every output in spec order, then the C return value:

```haskell
type family AssembleOutputs os r where
  AssembleOutputs '[]      r = r
  AssembleOutputs (a : os) r = AssembleOutputs os (a -> r)

resultPure
  :: UncurryOutputs os
  => AssembleOutputs os (c -> hs)
  -> ToHighLevel os (IO c) (IO hs)
resultPure f = ToHighLevel $ \pending cFn -> do
    c    <- cFn
    outs <- pending
    pure (uncurryOutputs f outs c)
```

`os` grows by one with each `output` above the closer, so by the time the closer
runs the types are concrete and nothing has to be inferred backwards out of it:

```haskell
output a $ output b $ resultPure (,,)               -- IO (a, b, c)
output a $ output b $ resultPure (\x y _ -> (x, y)) -- C return dropped
```

`resultIO` is the same, ending in `IO`.

## Inputs: one final example

```c
int strncmp(const char *s1, const char *s2, size_t n);
```

```haskell
c_strncmp :: PtrConst CChar -> PtrConst CChar -> CSize -> IO CInt

hsStrncmp :: String -> ByteString -> IO Int
hsStrncmp = toHighLevel c_strncmp
          $ input  withCStringIn
          $ input2 useAsByteStringLenIn
          $ resultPure fromIntegral
```

compiles to

```haskell
hsStrncmp s bs =
  withCString s $ \p1 ->
    BS.useAsCStringLen bs $ \(p2, n) ->
      fromIntegral <$> c_strncmp (unsafeFromPtr p1) (unsafeFromPtr (castPtr p2))
                                 (fromIntegral n)
```

No out-parameters, so `os` stays `'[]` throughout, `AssembleOutputs '[] (CInt -> Int)`
reduces to `CInt -> Int`, and `fromIntegral` is used at exactly that type. Nothing
here was inferred from a default.

## All combinators: one final example

```c
int render(int *out, const char *name, char *scratch, int flags);
```

```haskell
hsRender :: String -> IO Int
hsRender = toHighLevel c_render
         $ output defaultOut      -- int *out
         $ input  withCStringIn   -- const char *name
         $ scratchArray @CChar 16 -- char *scratch
         $ fixed  0               -- int flags
         $ checkedResult (throwUnlessZero RenderFailed)
```

compiles to

```haskell
hsRender name =
  alloca $ \out ->
    withCString name $ \cname ->
      allocaArray 16 $ \scratch -> do
        status <- c_render out (unsafeFromPtr cname) scratch 0
        throwUnlessZero RenderFailed status
        fromIntegral <$> peek out
```
