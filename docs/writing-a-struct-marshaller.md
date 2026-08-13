# Writing a struct marshaller

A `MarshalStruct` writes a high-level value into the C layout, and an
`UnmarshalStruct` reads one back.

```haskell
import Binding.Combinators (asArgument, asOutput, asResult, input, output,
                            resultPure, toHighLevel)
import Binding.Combinators.Marshaller (MarshalStruct, UnmarshalStruct, at,
                                       marshalNested, marshalOptional, scalar,
                                       struct, unmarshalField, unmarshalFieldPure,
                                       unmarshalNested, unmarshalOptional, (>>>))
import Binding.Combinators.Marshaller.Utils (useAsByteStringLenIn, withCStringIn)
```

## The example

A nested pair of structs, whose outer record carries a `(name, name_len)` string
and a nullable `label`:

```c
struct Inner { int x; int y; };
struct Outer { struct Inner pos; const char *name; size_t name_len;
               const char *label;  /* nullable */   double weight; };
```

The low-level structs arrive with the bindings, carrying their `StaticSize`,
`ReadRaw` and `WriteRaw` instances (found in `hs-bindgen-runtime`).

Write the high-level types to expose:

```haskell
data Inner = Inner CInt CInt
data Outer = Outer Inner (PtrConst CChar) CSize (PtrConst CChar) CDouble

data InnerHi = InnerHi { ix :: Int, iy :: Int }
data OuterHi = OuterHi
  { oPos :: InnerHi, oName :: ByteString, oLabel :: Maybe String, oWeight :: Double }
```

## The write side

Chain the fields in source order with `>>>` similarly to how one would use
`toHighLevel`. `at` aims each field at its marshaller, `marshalNested` inlines
the sub-struct, `useAsByteStringLenIn` fills the `(name, name_len)` pair from
one `ByteString`, and `marshalOptional` sends `Nothing` to a NULL `label`:

```haskell
innerIn :: MarshalStruct InnerHi Inner
innerIn = struct Inner
        (   at ix (scalar fromIntegral)
        >>> at iy (scalar fromIntegral)
        )

outerIn :: MarshalStruct OuterHi Outer
outerIn = struct Outer
        (   at oPos    (marshalNested innerIn)
        >>> at oName   useAsByteStringLenIn
        >>> at oLabel  (marshalOptional ($ nullCharPtr) withCStringIn)
        >>> at oWeight (scalar realToFrac)
        )
  where nullCharPtr = PtrConst.unsafeFromPtr nullPtr  -- a NULL const char *
```

## The read side

`unmarshalFieldPure` and `unmarshalField` read one field, the latter in
`IO`; `unmarshalOptional` turns a NULL pointer into `Nothing`; `unmarshalNested`
reads the sub-struct:

```haskell
innerOut :: UnmarshalStruct Inner InnerHi
innerOut = InnerHi <$> unmarshalFieldPure (\(Inner x _) -> x) fromIntegral
                   <*> unmarshalFieldPure (\(Inner _ y) -> y) fromIntegral

outerOut :: UnmarshalStruct Outer OuterHi
outerOut = OuterHi
  <$> unmarshalNested    (\(Outer pos _ _ _ _) -> pos) innerOut
  <*> unmarshalField     (\(Outer _ p n _ _) -> (p, n)) packName
  <*> unmarshalOptional  (\(Outer _ _ _ lbl _) -> PtrConst.unsafeToPtr lbl) peekCString
  <*> unmarshalFieldPure (\(Outer _ _ _ _ w) -> w) (\(CDouble d) -> d)
  where packName (p, n) = BS.packCStringLen (PtrConst.unsafeToPtr p, fromIntegral n)
```

## Dropping them into a spec

Through the adapter that matches how C takes the struct:

```c
int          takes_outer(struct Outer *); // by-value argument
int          fill_inner(struct Inner *);  // out-parameter
struct Inner make_inner(void);            // by-value return
```

```haskell
hsTakesOuter :: OuterHi -> IO Int
hsTakesOuter = toHighLevel c_takesOuter
             $ input (asArgument outerIn)
             $ resultPure fromIntegral

hsFillInner :: IO (InnerHi, Int)
hsFillInner = toHighLevel c_fillInner
            $ output (asOutput innerOut)
            $ resultPure (\i c -> (i, fromIntegral c))

hsMakeInner :: IO InnerHi
hsMakeInner = toHighLevel c_makeInner (asResult innerOut)
```

## Note

**Nothing frees what the fields point at.** `asOutput` reads the struct and stops
there, so a field holding C-allocated memory has to be copied and freed inside
`unmarshalField`.

To use a struct outside a spec, `withStruct` writes one and hands over the `Ptr`,
and `runUnmarshalStruct` reads one back.
