defmodule BharatRelayer.V2WorkerR2 do
  use BharatRelayer.V2Worker,
    relayer_idx: :r2,
    private_key_env: :relayer_2_private_key,
    name: BharatRelayer.V2WorkerR2
end
