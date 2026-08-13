# `binding-combinators`

Write high-level Haskell wrappers over low-level FFI bindings, declaratively.

Wrapping a C function by hand is repetitive: allocate a buffer, pass a `Ptr`,
thread an out-parameter, read it back, check a status code, free whatever C handed
back. This library gives you combinators for saying what each C argument is for,
and does the marshalling from that description.

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

That reads top to bottom like an annotated C prototype: one `input` per Haskell
argument, marshalled into the C argument or arguments it fills, closed by a
conversion of the return value. The approach is inspired by [c2hs][], but with no
custom syntax and no code generation step. A spec is an ordinary Haskell value, so
you can name it, reuse it, and let the type checker check it.

`c_strncmp` is the low-level binding, which this library does not produce. You
either write it yourself or generate it with [hs-bindgen][]; `PtrConst` is
hs-bindgen's read-only pointer, one of the types generated bindings are
written in.

## Installing

Requires GHC 9.2 or later. Tested on 9.2 through 9.14.

Not on Hackage yet. It depends on `hs-bindgen-runtime`, which is not on
Hackage (yet) either, so for now both come from git. In your `cabal.project`:

```cabal
source-repository-package
  type:     git
  location: https://github.com/well-typed/binding-combinators
  tag:      <commit>

source-repository-package
  type:     git
  location: https://github.com/well-typed/hs-bindgen
  tag:      <commit>
  subdir:   hs-bindgen-runtime
```

`hs-bindgen-runtime` supplies the types generated bindings are written in, which
the marshallers are defined against. The generator itself is not a dependency,
which is why this library is versioned separately.

## Documentation

- [Your first binding][doc:first].
- [Writing a spec][doc:writing].
- [Writing a struct marshaller][doc:structs].
- [Writing a combinator][doc:combinator].
- [How it works][doc:internals].
- The Haddock for `Binding.Combinators`.
- [`examples/`][examples] wraps three real C libraries: libgit2, libsodium and
  libclang.

## Status

Pre-release (alpha). The API is still settling.

Owned by Well-Typed LLP and Anduril Industries. BSD-3-Clause.

<!-- sources and references -->

[c2hs]: https://github.com/haskell/c2hs
[doc:combinator]: docs/writing-a-combinator.md
[doc:first]: docs/first-binding.md
[doc:internals]: docs/how-it-works.md
[doc:structs]: docs/writing-a-struct-marshaller.md
[doc:writing]: docs/writing-a-spec.md
[examples]: examples
[hs-bindgen]: https://github.com/well-typed/hs-bindgen
