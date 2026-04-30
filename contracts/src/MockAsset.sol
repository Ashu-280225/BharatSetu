// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "./utils/ERC721.sol";
import {Ownable} from "./utils/Ownable.sol";

/**
 * @title MockAsset
 * @notice Simulates a tokenized asset on the permissioned CBDC ledger.
 *         Each tokenId represents a distinct asset instance (bond, trade receivable, etc.)
 *         Owner (hub admin) can mint new asset tokens for testing.
 */
contract MockAsset is ERC721, Ownable {
    uint256 public nextTokenId;
    mapping(uint256 => string) public assetType; // e.g. "BOND", "TRADE_RECEIVABLE", "PROPERTY"

    event AssetMinted(address indexed to, uint256 tokenId, string assetType);

    constructor() ERC721("BharatSetu Tokenized Asset", "BSTA") {}

    function mint(address to, string calldata _assetType) external onlyOwner returns (uint256 tokenId) {
        tokenId = nextTokenId++;
        assetType[tokenId] = _assetType;
        _mint(to, tokenId);
        emit AssetMinted(to, tokenId, _assetType);
    }
}
