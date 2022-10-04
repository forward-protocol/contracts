### Forward

Forward is an NFT liquidity protocol that enables market makers to provide efficient liquidity for collectors while at the same time preserving royalties to creators. See more details and context in the [protocol docs](https://forward-protocol.readme.io/docs/getting-started).

The Forward protocol consists of two core parts:

- the exchange contract (which allows market makers to create bids on standard-compliant NFTs)
- the user vaults (which act as an escrow for the items received as part of bid acceptance)

#### Exchange contract

Heavily inspired by Seaport, the Forward exchange contract provides similar functionality - partially-fillable bids on standard-compliant ERC721 and ERC1155 tokens. A prerequisite for creating bids via Forward is that each user must initialize their wallet by deploying a vault contract where any locked items will get escrowed. This is done via the `createVault` method which uses [EIP1167](https://eips.ethereum.org/EIPS/eip-1167) under the hood for gas-efficient deployments.

As explained in the protocol docs, the core goal of the protocol is to avoid having market makers pay the royalties twice (both when buying and when selling). The way Forward solves this is by having the bought NFT(s) and the bid royalties get locked until the market maker sells the NFT(s) via a royalty-paying listing. However, simply enforcing the listing is royalty-paying can easily be evaded (eg. by creating a just-in-time zero-priced listing privately relayed so that no one else is able to fill other than the market maker). Forward solves this issue by enforcing the listing royalties to be within a percentage of the locked bid royalties. This is a configurable parameter on the `Forward` contract (in fact this is the only parameter the contract owner can configure).

##### Creating bids

Forward supports 4 kinds of bids:

- single-token ERC721 bids
- single-token ERC1155 bids
- multi-token ERC721 bids
- multi-token ERC1155 bids

The "single-token" kind represents bids on a particular token id within an NFT contract, while the "multi-token" kind represents bids on any token id within a predefined list of token ids of a particular NFT contract. Cross-contract bids are not supported. The "multi-token" bids are enforced via merkle proofs of inclusion (eg. the bid's maker signs the merkle root of all token ids included in the bid while the taker must provide a merkle proof attesting that the token id they're trying to fill is included in the merkle root of the bid).

All bid kinds support an `amount` (which represents the maximum number of times an order can get filled) and are partially-fillable (takers are able to fill fractions of the original bid's amount).

On bid acceptance, Forward will lock any royalties to get paid (as specified via the [royalty registry](https://royaltyregistry.xyz/)) together with the bought NFT(s) in the maker's vault.

#### User vaults

Once the royalties and the NFT(s) are locked in the vault, a user has two options:

- sell the NFT(s) via Seaport (the listing must be royalty-paying) - if the listing is deemed valid by the protocol, the locked bid royalties associated to the NFT(s) will get refunded to the maker (since they already paid royalties via the Seaport listing)
- force unlock the NFTs - in this case the locked bid royalties associated to the NFT(s) will get paid accordingly

Forward enforces that any Seaport listings originating from a user vault is royalty-paying by using [EIP1271](https://eips.ethereum.org/EIPS/eip-1271) signatures. The signature data must be a packed-encoded representation of the order so that the vault contract can easily verify that the offer and consideration items of the order adhere to some predefined rules:

- the order has a single offer item which is the NFT to get sold
- the order only contains non-NFT consideration items and it includes royalty payments

Ideally the Seaport listing is OpenSea compatible so that it can be exposed to OpenSea's orderbook.

##### Limitations

- only WETH bids and ETH listings are supported
- once a listing gets accepted, an additional unlock step is needed for getting the bid royalties unlocked (although this could be hacked via a Seaport consideration tip item, depending on the fill source not all front-ends will automatically include it)
