# Your first binding

Everything below is compiled and tested as
[`test/Test/Binding/Combinators/FirstBinding.hs`][module].

For the vocabulary in full, read [Writing a spec](writing-a-spec.md) next.

## What we are wrapping

```c
double frexp(double x, int *exp);
double hypot(double x, double y);
```

`frexp` splits a double into a mantissa and an exponent. It returns the mantissa
and writes the exponent into a caller-allocated `int`, this function has all
three parts a spec deals with: an ordinary argument, an out-parameter, and a
return value.

## The imports

```haskell
import Foreign.C.Types (CDouble (..), CInt (..))
import Foreign.Ptr (Ptr)

import Binding.Combinators (input, output, resultPure, toHighLevel)
import Binding.Combinators.Auto (auto)
import Binding.Combinators.Marshaller (scalar, unmarshalOutPure)
```

## The low-level bindings

A generated binding would be the same declaration with hs-bindgen's types in
place of the raw ones.

```haskell
foreign import ccall unsafe "math.h frexp"
  c_frexp :: CDouble -> Ptr CInt -> IO CDouble

foreign import ccall unsafe "math.h hypot"
  c_hypot :: CDouble -> CDouble -> IO CDouble
```

## The wrapper

Write the high-level type signature first. Everything in the spec is checked
against it (including `auto`), so without one the errors stop being about
marshalling and start being about ambiguity.

```haskell
hsFrexp :: Double -> IO (Int, Double)
hsFrexp = toHighLevel c_frexp
        $ input  (scalar realToFrac)
        $ output (unmarshalOutPure fromIntegral)
        $ resultPure (\e m -> (e, realToFrac m))
```

Reading it top to bottom against the C prototype:

- `toHighLevel c_frexp` applies the spec below it to the low level binding.
- `input (scalar realToFrac)` fills `double x`. `scalar` builds a marshaller from
  a pure conversion, here `Double -> CDouble`.
- `output (unmarshalOutPure fromIntegral)` fills `int *exp`. It allocates the slot
  before the call and peeks it after, converting `CInt` to `Int`.
- `resultPure (\e m -> (e, realToFrac m))` closes the spec. The assembler receives
  each output in spec order, then the C return value, so `e` is the exponent and
  `m` is the mantissa.

## Using auto

`hypot` needs no decisions: two `double` arguments the signature takes as
`Double`, and a `double` return it takes as `Double`. `auto` writes all of it.

```haskell
hsHypot :: Double -> Double -> IO Double
hsHypot = toHighLevel c_hypot auto
```

That is the whole binding. `auto` cannot write the `frexp` one, because nothing in
`Ptr CInt` says whether C reads that pointer, writes it, or treats it as an array.

## Where to go next

- [Writing a spec](writing-a-spec.md) for the rest of the vocabulary, `auto` in
  full, and the typed-hole workflow.
- [Writing a struct marshaller](writing-a-struct-marshaller.md) once C hands you a
  struct.
- [How it works](how-it-works.md) for the machinery underneath.

[module]: ../test/Test/Binding/Combinators/FirstBinding.hs
