-- | The CSPRNG.
module LibSodium.Random
  ( randomBytes
  ) where

import Data.ByteString (ByteString)

import Binding.Combinators (fixed, output, toHighLevel)
import Binding.Combinators.Auto (autoResult)
import Binding.Combinators.Marshaller.Utils (byteStringOut)

import Generated.Randombytes.Safe (randombytes_buf)

-- | @n@ cryptographically random bytes from libsodium's CSPRNG
-- (@randombytes_buf@).
randomBytes :: Int -> IO ByteString
randomBytes n = toHighLevel randombytes_buf
              $ output (byteStringOut n) -- void *buf
              $ fixed  (fromIntegral n)  -- size_t size
              $ autoResult
