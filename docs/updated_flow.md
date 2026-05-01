Channel:
Contains 2 zones , 1 Hub (regulator node or relayer node, Escrow account(s), State validation ?(State copy or snapshot)

Flow:
Action: 
1. User initiates swap with tokens(ERC or SPL), destination wallet address.
2. We will figure out an unique identifier (channel specific, zone specific) for this txn, mapping table, changeable logic based on usecases.
3. Lock tokens in Escrow (sender)
4. Records transaction state as locked in txn pool. (Txn Pool is within HUB).
5. Relayer will validate the Zone A’s chain txn state and trigger subsequent action to be performed on zone B’s chain (destination chain).
6.A. Wrapped ETH is minted on solana and wrapped ETH value is derived from the lock ETH. (Original ETH is lock in vault and that vault is in ETH network.)
7. Within Zone B there will be a consensus for the triggered event by relayer.
8. There will be a commit in Zone A and Zone B , and txnx state will be written in both the chains and a copy will be with HUB(relayer).



Reverse Flow


1. User initiates swap with tokens(SPL or ERC), with destination wallet address. Version of token is checked on this step in that a Wrapped version or original version.
2. We will figure out an unique identifier (channel specific, zone specific) for this txn, mapping table, changeable logic based on usecases.
3. Lock tokens in Escrow (sender)
4. Records transaction state as locked in txn pool. (Txn Pool is within HUB).
5. Relayer will validate the Zone B’s chain txn state and trigger subsequent action to be performed on zone A’s chain (destination chain).
6. If solana token is original one then token is lock and if it is a wrapped version then token is going to burned burned after token mint confirmation from the Zone A.
7. Within Zone B there will be a consensus for the triggered event by relayer.
8. There will be a commit in Zone B and Zone A , and txnx state will be written in both the chains and a copy will be with HUB(relayer).




Asset Flow
User connect its wallet address to the platform and initiate NFT to transfer from  Zone A to Zone B with destination wallet address.
NFT is lock in Escrow in account and a receipt is generated with its description and meta data.
This NFT Transfer request will be validated by relayer by comparing the state. 
Once the state is validated token or NFT transfer initiation to the receiver account will be initiated.
Relayer will initiate instruction in corresponding zone b to create a wrapped version of NFT.
Wrapped version is minted in the destination wallet address.
There will be a commit in Zone B and Zone A , and txnx state will be written in both the chains and a copy will be with HUB(relayer).


Reverse Asset Flow
User connect its wallet address to the platform and initiate NFT to transfer from  Zone B to Zone A with destination wallet address.
Wrapped NFT is lock in Escrow in account and a receipt is generated with its description and meta data.
This NFT Transfer request will be validated by relayer by comparing the state. 
Once the state is validated token or NFT transfer initiation to the receiver account will be initiated.
Relayer will initiate instruction in corresponding zone A to release the original NFT in the source wallet using wrapped version.
And wrapped version is burned in Zone B after successful transaction confirmation from the relayer.
There will be a commit in Zone B and Zone A , and txnx state will be written in both the chains and a copy will be with HUB(relayer).


Note :- In case of any failure at any stage the entire transaction will be rolled backed to the initial state.(Applicable to all flows)
