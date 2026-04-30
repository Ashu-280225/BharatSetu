defmodule BharatRelayer.V2WorkerR1 do
  use BharatRelayer.V2Worker,
    relayer_idx: :r1,
    private_key_env: :relayer_1_private_key,
    name: BharatRelayer.V2WorkerR1
end
