// SPDX-License-Identifier: MIT

/// @title Bluxe NFT Contract

/** 
  @notice An `ERC721` NFT contract with `ERC2981` Royalty Standard,
   on-chain metadata storage, lazy minting with `EIP-712` signatures,
   and token burning with owner-approved burners.
*/

/**  
 @author Izaq Sana.
 GitHub: https://github.com/0xSmartCoder
 LinkedIn: https://www.linkedin.com/in/izaq-b8674233a
*/

pragma solidity ^0.8.28;
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC2981} from "@openzeppelin/contracts/token/common/ERC2981.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

// Custom Errors
error AddressNotValid(address minter);
error ROYALTY_RECEIVERNotValid(address ROYALTY_RECEIVER);
error NotTokenOwnerNotOwner(uint256 tokenId);
error BurningNotApproved(uint256 tokenId);
error TooMuchSupply(uint256 supply);
error InvalidSignature(address signer);
error VoucherUsed(uint256 nonce);
error InsufficientPayment();
error TooHighRoyalty(uint96 fee);
contract BluxeToken is ERC721, ERC2981, Ownable, EIP712 {
    // State Variables
    uint256 private nextTokenId;

    /// @notice default maximum supply is 10,000 NFTs
    uint256 public maximumSupply = 10000;

    /// @notice Royalty Info is IMMUTABLE after deployment
    address public immutable ROYALTY_RECEIVER;
    uint96 public immutable FRACTION_ROYALTY_BPS;
    using ECDSA for bytes32;
    event MINTED(address indexed to, uint256 indexed tokenId);
    event BURNED(uint256 indexed tokenId, address sender);
    constructor(
        string memory name,
        string memory symbol,
        address owner,
        uint96 _fraction_Royalty_Bps,
        address _royalty_Receiver
    ) ERC721(name, symbol) EIP712(name, "1") Ownable(owner) {
        if (_fraction_Royalty_Bps > 1000) revert TooHighRoyalty(_fraction_Royalty_Bps);
        ROYALTY_RECEIVER = _royalty_Receiver;
        FRACTION_ROYALTY_BPS = _fraction_Royalty_Bps;
        /**
     @notice OpenZeppelin @Latest version's Ownable.sol needs an address to set owner (msg.sender),
      we need to specify on Constructor.
    */
    }

    /** @dev Lazy minting is a process in the NFT (non-fungible token)
 space that allows creators to mint tokens only when they are sold
 or transferred, rather than at the time of creation. 
 */

    struct LazyVoucher {
        string n; // name
        string i; // image
        string d; // description
        uint256 p; // price
        address c; // creator
        uint256 nonce; // unique nonce
    }

    /// @dev Mapping to prevent double-redeem
    mapping(address => mapping(uint256 => bool)) public usedNonces;

    bytes32 private constant VOUCHER_TYPEHASH =
        (
            keccak256(
                "LazyVoucher(string n, string i, string d, uint256 p, address c, uint256 nonce)"
            )
        );

    function _hashVoucher(LazyVoucher calldata v /*Voucher*/) public view returns (bytes32) {
        return
            _hashTypedDataV4(
                keccak256(
                    abi.encode(
                        VOUCHER_TYPEHASH,
                        keccak256(bytes(v.n)),
                        keccak256(bytes(v.i)),
                        keccak256(bytes(v.d)),
                        v.p,
                        v.c,
                        v.nonce
                    )
                )
            );
    }

    // Verify signature
    function _verify(
        LazyVoucher calldata v /*Voucher*/,
        bytes calldata sig /*Signature*/
    ) internal view returns (address) {
        bytes32 digest = _hashVoucher(v);
        return ECDSA.recover(digest, sig);
    }

    // Redeem function (actual lazy mint)
    function redeem(
        LazyVoucher calldata v /*Voucher*/,
        bytes calldata sig /*Signature*/
    ) external payable {
        address signer = _verify(v, sig);
        if (signer == address(0)) {
            revert InvalidSignature(signer);
        }
        if (usedNonces[signer][v.nonce]) {
            revert VoucherUsed(v.nonce);
        }
        if (msg.value < v.p) {
            revert InsufficientPayment();
        }

        /// @dev mark nonce as used to avoid re-use voucher
        usedNonces[signer][v.nonce] = true;

        if (nextTokenId >= maximumSupply) revert TooMuchSupply(maximumSupply);

        // token ID to be minted & increment `nextTokenId` for next mint
        uint256 tokenId = nextTokenId++;

        _mint(msg.sender, tokenId);

        nftData[tokenId] = NftData(v.n, v.i, v.d);

        // send payment to signer (creator)
        (bool success, ) = payable(signer).call{value: msg.value}("");
        require(success, "Payment Failed");

        emit MINTED(msg.sender, tokenId);
    }

    struct NftData {
        string n; // nft name
        string i; // nft image URI e.g-> ipfs://...
        string d; // nft description
    }

    // tokenId => (address => approvedToBurn)
    mapping(uint256 => mapping(address => bool)) private isOwnerApproved;
    // tokenId => NftData
    mapping(uint256 => NftData) private nftData;

    // @dev Mint function
    function mint(string calldata n, string calldata i, string calldata d, address to) external {
        if (to == address(0)) {
            revert AddressNotValid(to);
        }

        // check supply limit if exceeded
        if (nextTokenId >= maximumSupply) revert TooMuchSupply(maximumSupply);
        uint256 tokenId = nextTokenId++;
        if (ROYALTY_RECEIVER != address(0) && FRACTION_ROYALTY_BPS > 0) {
            _setTokenRoyalty(tokenId, ROYALTY_RECEIVER, FRACTION_ROYALTY_BPS);
        } else {
            revert ROYALTY_RECEIVERNotValid(ROYALTY_RECEIVER);
        }

        _mint(to, tokenId);

        /* store metadata on-chain mapping (we
 generate tokenURI dynamically from this) */
        nftData[tokenId] = NftData(n, i, d);
        emit MINTED(to, tokenId);
    }

    function tokenURI(uint256 tokenId) public view override(ERC721) returns (string memory) {
        NftData memory _nftData = nftData[tokenId];
        string memory json = Base64.encode(
            bytes(
                string(
                    abi.encodePacked(
                        "{",
                        '"name": "',
                        // token name
                        _nftData.n,
                        '",',
                        '"description": "',
                        // token description
                        _nftData.d,
                        '",',
                        '"image": "',
                        // token image URI e.g-> ipfs://...
                        _nftData.i,
                        '"',
                        "}"
                    )
                )
            )
        );

        // return data URI with Base64 encoded JSON solvers can read
        return string(abi.encodePacked("data:application/json;base64,", json));
    }
    /*
*@notice only token owner or operator can Approve who can 
  Burn the token.
*@param Burner address to allow to burn
 this token.
*@param tokenId the token Id
*/
    function approveBurn(address burner, uint256 tokenId) external returns (bool) {
        address currentOwner = ownerOf(tokenId);

        // msg.sender must be the `Token Owner` or `Operator`
        if (msg.sender != currentOwner && !isApprovedForAll(currentOwner, msg.sender)) {
            revert NotTokenOwnerNotOwner(tokenId);
        }
        // approve the `burner`
        isOwnerApproved[tokenId][burner] = true;
        return true;
    }

    /*
*@param Burner address: the address that calls approvedaBurn function for approval
*@param tokenId the `token Id` to revoke burn approval

*/
    function revokeBurnApproval(address burner, uint256 tokenId) external returns (bool) {
        address currentOwner = ownerOf(tokenId);

        // msg.sender must be the `Token Owner` or `Operator`
        if (msg.sender != currentOwner && !isApprovedForAll(currentOwner, msg.sender)) {
            revert NotTokenOwnerNotOwner(tokenId);
        }

        // revoke the `burner`
        isOwnerApproved[tokenId][burner] = false;
        return true;
    }
    function burn(uint256 tokenId) external {
        if (!isOwnerApproved[tokenId][msg.sender]) {
            revert BurningNotApproved(tokenId);
        }
        // clean metadata mapping.
        delete nftData[tokenId];

        // reset per-Token rayalty (Clean ERC2981 storage)
        _resetTokenRoyalty(tokenId);
        _burn(tokenId);
        emit BURNED(tokenId, msg.sender);
    }

    // @note: Only Owner can set the default royalty for the collection
    // function setDefaultRoyalty(address receiver, uint96 FRACTION_ROYALTY_BPS)external onlyOwner() {
    // _setDefaultRoyalty(receiver, FRACTION_ROYALTY_BPS);
    // }

    // @note: Only owner of this contract can change maxSupply.
    function setMaxSupply(uint256 newLimit) public onlyOwner {
        // check new limit must not exceed 10,000
        if (newLimit > 10000) {
            revert TooMuchSupply(newLimit);
        }
        maximumSupply = newLimit;
    }

    // Override supportsInterface
    function supportsInterface(
        bytes4 interfaceId
    ) public view override(ERC721, ERC2981) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    // get next Token ID
    function getNextTokenID() public view returns (uint256) {
        return nextTokenId;
    }
}
