defmodule BharatRelayer.V2WorkerR3 do
  use BharatRelayer.V2Worker,
    relayer_idx: :r3,
    private_key_env: :relayer_3_private_key,
    name: BharatRelayer.V2WorkerR3
end
