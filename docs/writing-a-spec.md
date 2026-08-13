# Writing a spec

If you have not built a binding with this library before, [Your first
binding](first-binding.md) offers a simpler example and overview, it goes from
an empty file to a working wrapper in one module.

## One combinator per C argument

A spec is one combinator per C argument, top to bottom, closed by a combinator
that deals with the return value. `input` takes one Haskell argument and marshals
it into one C argument; `input2` marshals one Haskell argument into two, which is
what a `(pointer, length)` pair wants; `resultPure` converts the return value.

```c
int strncmp(const char *str1, const char *str2, size_t n);
```

```haskell
c_strncmp :: PtrConst CChar -> PtrConst CChar -> CSize -> IO CInt

hsStrncmp :: String -> ByteString -> IO Int
hsStrncmp = toHighLevel c_strncmp
          $ input  withCStringIn        -- const char *str1
          $ input2 useAsByteStringLenIn -- str2, n
          $ resultPure fromIntegral
```

It reads like an annotated copy of the low level C binding like one could do
in [c2hs][]. The `String` fills one C argument and the `ByteString` fills two, so
two Haskell arguments cover three C ones, and the high-level type says so.

`withCStringIn` and `useAsByteStringLenIn` are ready-made marshallers from
`Binding.Combinators.Marshaller.Utils`. When the conversion is obvious from
the types, `defaultIn` picks one for you, and the whole spec above shortens to
`autoWith fromIntegral`. More on that below.

## Out-parameters

`crypto_sign_detached`'s signature reads by writing into two caller-allocated
slots and reports success in its return value. Each `output` allocates a slot
and reads it back after the call. The closer's function receives every output
in spec order and then the C return value, so `takeSignature` here is a
`ByteString -> Int -> CInt -> IO Signature`:

```c
int crypto_sign_detached(unsigned char *sig, unsigned long long *siglen_p,
                         const unsigned char *m, unsigned long long mlen,
                         const unsigned char *sk);
```

```haskell
signDetached :: SecretKey -> ByteString -> Signature
signDetached secretKey message = toHighLevelPure crypto_sign_detached
  ( output (byteStringOut signatureBytes)  -- unsigned char *sig
  $ output (unmarshalOutPure fromIntegral) -- unsigned long long *siglen_p
  $ input2 unsafeByteStringLenIn           -- m, mlen
  $ input  defaultIn                       -- const unsigned char *sk
  $ resultIO (takeSignature "crypto_sign_detached")
  ) message secretKey
```

Note `toHighLevelPure` rather than `toHighLevel`. It runs the spec the same way
and then takes the `IO` off the result, via `unsafePerformIO`, which you may do
whenever the call is a function of its arguments. Ed25519 signing is one.

## Letting `auto` write the ordinary combinators

For the simpler bindings that don't have output parameters,  `auto` tackles
the high-level type signature.

```c
int sodium_library_version_major(void);
```

```haskell
major :: IO Int
major = toHighLevel sodium_library_version_major auto
```

That is the whole binding. `auto` filled the arguments, of which there are none,
and converted the `int` to `Int` because the signature asks for `Int`.

## Automating only the inputs, or only the result

`auto` runs to the end of the spec once it starts, so on its own it is all or
nothing. However, there are two variants that give back one half each.

**`autoResult` fills the result only,** leaving the combinators to you. Here a
single `output` is the entire result, so there is nothing left to decide about
it and the `()` value of `crypto_secretbox_keygen` is _automatically_ ignored:

```c
void crypto_secretbox_keygen(unsigned char k[32]);
```

```haskell
newKey :: IO Key
newKey = toHighLevel crypto_secretbox_keygen
       $ output (Key <$> byteStringOut keyBytes)
       $ autoResult
```

**`autoInputs` fills the inputs only,** then hands over to you to fill the
rest. It composes with any closer. Three combinations come up often enough to
have their own names (`autoChecked`, `autoMaybe`, `autoWith`).

The module header of `Binding.Combinators.Auto` offers a nice table summary of
all usable combinators, comparing against each other, by whether they fill the
arguments and how they close.

## Mixing hand-written and automatic combinators

A real binding usually cannot be one-shot with `auto`.
`qrcodegen_encodeText` is an example because it requires a scratch buffer the
caller allocates but never reads, an out-parameter holding the QR code, and
five ordinary arguments:

```c
bool qrcodegen_encodeText(const char *text, uint8_t tempBuffer[], uint8_t qrcode[],
                          enum qrcodegen_Ecc ecl, int minVersion, int maxVersion,
                          enum qrcodegen_Mask mask, bool boostEcl);
```

Write out only the combinators that need a decision. `scratchArray` allocates the temp
buffer and keeps it out of the type signature, `output` keeps the QR code, and
`auto` fills everything else from the signature, the result included:

```haskell
encodeText
  :: String -> Qrcodegen_Ecc -> Int -> Int -> Qrcodegen_Mask -> Bool
  -> IO (IncompleteArray Word8, Bool)
encodeText = toHighLevel qrcodegen_encodeText
           $ input defaultIn     -- text (String)
           $ scratchArray maxLen -- tempBuffer: written, never read
           $ output qrCodeOut    -- qrcode: the out-parameter we keep
           $ auto                -- ecl, minVersion, maxVersion, mask, boostEcl,
                                 -- then the (qrcode, ok) result
  where
    qrCodeOut = peekIncompleteArrayOut maxLen
```

`auto` closes the spec once it starts, which is why the leading `text`
argument is written out as `input defaultIn` rather than left to `auto`.

## Writing a spec you do not know the shape of

One of the recommended ways to build a spec is to build it against typed holes
and let the GHC typed hole messages tell you. The absolute first thing to do
is to write the high-level type signature you want, then hold a hole at the
combinator you are working on and stub the tail with `auto`, which unlike
`undefined` constrains what sits above it:

```haskell
-- lowLevel :: C_A -> Ptr C_B -> IO C_C

highLevel :: A -> IO (B, C)
highLevel = toHighLevel lowLevel
          $ input _
          $ output _
          $ auto
```

"Building against typed holes" in the Haddock for `Binding.Combinators` works
this through in more detail, including why `auto` is the stub to use and why
the fixed-arity `input` / `input2` / `input3` instead of `inputN` is
recommended when working with typed holes.

One flag worth knowing: `-funclutter-valid-hole-fits` trims the hole-fit lists,
which are long here because every marshaller in scope fits a `Marshal` hole.

## Testing a binding

`toHighLevel` takes any function, not specifically a low level C `foreign
import`. So a spec can be run against a Haskell function with the C function's
type (or not). This allows to test the marshalling without linking anything:

```haskell
cAdd :: CInt -> CInt -> IO CInt
cAdd a b = pure (a + b)

hsAdd :: Int -> Int -> IO Int
hsAdd = toHighLevel cAdd auto
```

This library's own suite is written that way, in `test/`.

<!-- sources and references -->

[c2hs]: https://github.com/haskell/c2hs
