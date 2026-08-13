# Writing a combinator

A C library usually has one or two conventions repeated across a lot of its
functions. For example: every constructor fills an out-parameter and returns a
status, every accessor hands back a borrowed pointer, every getter fills a
caller-sized buffer. Writing each of those out by hand is tiresome.

Since a spec is an ordinary Haskell value, you can abstract over a convention
with ordinary Haskell.

In order to write a combinator one needs two things a spec never mentions,
both from `Binding.Combinators`: the `ToHighLevel` type itself, and the
`ThreadIn` constraint that every argument-filling combinator carries.

```haskell
import Binding.Combinators (ThreadIn, ToHighLevel, input, output, toHighLevel)
```

## libgit2's handle constructors

libgit2 has a few functions that all have the same three-part shape.

```c
int  git_repository_open (git_repository **out, const char *path);
int  git_commit_lookup   (git_commit **out, git_repository *repo, const git_oid *id);
int  git_revwalk_new     (git_revwalk **out, git_repository *repo);

void git_repository_free (git_repository *repo);
void git_commit_free     (git_commit *commit);
void git_revwalk_free    (git_revwalk *walk);
```

A `git_X **out` slot to fill (with a corresponding `git_X_free` function),
then some inputs, then a status: `0` for success, a negative code for failure,
with the message left in thread-local state. Only the middle part differs, in
how many arguments it has.

A `git_X *` is opaque and has to be freed exactly once, so each becomes a
newtype over a `ForeignPtr` carrying its own `git_X_free` as the finaliser.
Freeing then happens at GC and no caller ever calls it:

```haskell
newtype Repository = Repository (ForeignPtr Git_repository)
newtype Commit     = Commit     (ForeignPtr Git_commit)
newtype Revwalk    = Revwalk    (ForeignPtr Git_revwalk)
```

libgit2 has ten of these, all with the same two operations, so one class
abstracts over them. `CRep h` is the generated C type a handle wraps, and it
is injective because no two handles wrap the same one:

```haskell
class Handle h where
  type CRep h = r | r -> h          -- CRep Commit = Git_commit, and back again
  toFP   :: h -> ForeignPtr (CRep h)
  fromFP :: ForeignPtr (CRep h) -> h

instance Handle Commit where
  type CRep Commit = Git_commit
  toFP (Commit p)  = p
  fromFP           = Commit
```

Two marshallers follow from this directly. One passes a handle to C, holding the
`ForeignPtr` alive across the call so the finaliser cannot fire mid-call; the
other fills a `git_X **` slot and attaches the finaliser to whatever C wrote
there:

```haskell
handleIn  :: Handle h => Marshal h (Ptr (CRep h) -> lo) lo
handleIn  = bracket (\h -> withForeignPtr (toFP h))

outHandle :: Handle h => FinalizerPtr (CRep h) -> Unmarshaller (Ptr (Ptr (CRep h))) h
outHandle = fmap fromFP . outForeignPtr
```

The status checking convention is worth naming once too, since every failing
call in the library shares it:

```haskell
checkStatus :: CInt -> IO ()
checkStatus n | n < 0     = throwIO =<< gitError n -- reads git_error_last
              | otherwise = pure ()

checkedStatus :: AutoOutputs os hs => ToHighLevel os (IO CInt) (IO hs)
checkedStatus = checkedResult checkStatus
```

With these in hand, the three constructors are one spec written three times:

```haskell
repositoryOpen :: Text -> IO Repository
repositoryOpen = toHighLevel git_repository_open
               $ output (outHandle git_repository_free)
               $ input textIn
               $ checkedStatus

commitLookup :: Repository -> Oid -> IO Commit
commitLookup = toHighLevel git_commit_lookup
             $ output (outHandle git_commit_free)
             $ input handleIn
             $ input oidInC
             $ checkedStatus

revwalkNew :: Repository -> IO Revwalk
revwalkNew = toHighLevel git_revwalk_new
           $ output (outHandle git_revwalk_free)
           $ input handleIn
           $ checkedStatus
```

`toHighLevel` on the C function, one `output (outHandle ...)` for the handle
it produces, and `checkedStatus` at the bottom. Only the inputs in between
vary, in number and in kind.

Knowing this we can abstract further, taking the middle `input`s as an
argument. `input textIn` and `input handleIn . input oidInC` are both
functions and take the rest of the spec, giving back the chain with the rest
attached.

```haskell
newHandle
  :: (Handle h, ThreadIn hi)
  => FinalizerPtr (CRep h)                                         -- git_X_free
  -> (ToHighLevel '[h] (IO CInt) (IO h) -> ToHighLevel '[h] lo hi) -- the caller's inputs
  -> (Ptr (Ptr (CRep h)) -> lo)                                    -- the C function
  -> hi
newHandle fin inputs = flip toHighLevel
                     $ output (outHandle fin)
                     $ inputs checkedStatus
```

- `'[h]` is the spec's output list. This spec collects exactly one out-parameter,
  the handle, and it is still sitting there when `checkedStatus` collects it. The
  caller's slice sits inside that, which is why `'[h]` appears at both of its ends.
- The second argument is a function from the closer to the finished spec, which is
  the type of a chain of `input`s composed with `.`.
- `flip toHighLevel`, because `toHighLevel` wants the C function first and here it
  arrives last, as the argument that makes `newHandle` applicable to a raw
  `foreign import`.

Each constructor is now one line, whatever its arity:

```haskell
repositoryOpen :: Text -> IO Repository
repositoryOpen = newHandle git_repository_free (input textIn) git_repository_open

commitLookup :: Repository -> Oid -> IO Commit
commitLookup = newHandle git_commit_free (input handleIn . input oidInC) git_commit_lookup

revwalkNew :: Repository -> IO Revwalk
revwalkNew = newHandle git_revwalk_free (input handleIn) git_revwalk_new
```

libgit2's ten handle types and every one of their constructors go through that
single definition.

## When the shape changes

`newHandle` gets away with plain parametrisation because it knows the shape of the
specs it builds: always one out-parameter, always closed by `checkedStatus`. Only
the inputs vary, and they vary as a value it can take.

A combinator that has to work at *any* (read polymorphic) number of arguments,
or *any* (again polymorphic) number of out-parameters, or *any* (polymorphic)
C return type cannot take those as values. It has to say in its context how
the types line up, and four constraints cover that: `Auto`, `AutoInputs`,
`AutoOutputs` and `AutoResult`.

"Naming a convention of your own" in the Haddock for `Binding.Combinators.Auto`
is the reference for those four.
