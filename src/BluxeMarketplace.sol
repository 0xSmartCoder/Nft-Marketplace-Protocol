// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title Bluxe Marketplace
/// @author Izaq (Bluxe Labs)
/// @notice Core marketplace contract for NFT trading in the Bluxe Web3 ecosystem

/// @custom:github https://github.com/0xSmartCoder
/// @custom:linkedin https://www.linkedin.com/in/izaq-b8674233a

/// @title BluxeMarketplace
/// @notice A decentralized marketplace for listing, buying, selling, and making offers on NFTs.
/// @dev Supports ERC721 tokens and the ERC2981 royalties standard.
///      Uses OpenZeppelin libraries for security, access control, and safe token transfers.
///      Handles both native ETH and wETH payments to enable cross-chain flexibility.

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {BluxeStorage} from "./BluxeStorage.sol";
import {BluxeBidManager} from "./BluxeBidManager.sol";
import {BluxeOfferManager} from "./BluxeOfferManager.sol";

/// @dev All custom errors
error NotTokenOwner(uint256);
error ListingIsNotActive(uint256);
error AlreadyAccepted();
error AuctionNotEndedYet(uint256);
error InvalidNFT();
error InvalidPrice(uint256);
error AlreadyListed();
error ListingIsNotInAuctionMode(uint256);
error NotYourListing(uint256);
error AlreadyClaimed(uint256);
error priceTooHigh(uint96);
error BadPlatformRecipient(address);
error CannotBuyOwnListing(address);
error NotActive(uint256);
error OnlySellerCanFinalize(address);
error BidActiveOnListing();
error NotAuthorized();
error ListingInAuctionModeCannotAllowedDirectBuy(uint256);
error NotEnoughETH(uint256);
error InsufficientBalance(uint256);
error ListingDoesNotExist(uint256 tokenId);
error InvalidAuctionEndTime(uint256);
error Not_Aproved();
error NFTTransferFailed();
error _NotOwner();
error _ZeroAddress();

contract BluxeMarketplace is ReentrancyGuard, IERC721Receiver {
    using SafeERC20 for IERC20;

    /// @dev Events
    event Listed(
        address nftContract,
        address indexed seller,
        uint256 indexed price,
        uint256 indexed tokenId,
        uint256 listingId
    );
    event Cancelled(
        address indexed nftContract,
        address indexed seller,
        uint256 indexed tokenId,
        uint256 listingId
    );
    event PlatformFeeUpdated(uint256 indexed newPrice, address indexed newReceipient);
    event ItemPurchased(
        address nftContract,
        uint256 indexed tokenId,
        address indexed buyer,
        address seller,
        uint256 price
    );
    event OfferRefundable(
        address nftContract,
        address indexed seller,
        uint256 indexed tokenId,
        uint256 listingId
    );
    event WithdrawnWETH(address indexed user, uint256 amount);
    event WithdrawnETH(address indexed user, uint256 amount);
    event AuctionFinalized(
        address indexed nftContract,
        uint256 indexed tokenId,
        address bidder,
        address seller,
        uint256 bidAmount,
        uint256 listingId,
        BluxeStorage.BidTokenType tokenType
    );
    event AuctionNFTClaimed(address nft, uint256 tokenId, address receiver, uint256 listingId);
    event OfferAccepted(
        address indexed nftContract,
        address indexed seller,
        address indexed buyer,
        uint256 tokenId,
        uint256 amount,
        uint256 listingId
    );
    event OfferNFTClaimed(address nft, uint256 tokenId, address receiver, uint256 listingId);
    event NFTBlocked(address nftContract, uint256 tokenId, uint256 listingId);

    /// @dev Bluxe Storage
    BluxeStorage public store;
    uint256 public nextListingId;

    constructor(address storageAdr) {
        store = BluxeStorage(storageAdr);
    }

    function _bidContract() internal view returns (BluxeBidManager) {
        address adr = store.bidManager();
        if (adr == address(0)) revert _ZeroAddress();
        return BluxeBidManager(payable(adr));
    }

    function _offerContract() internal view returns (BluxeOfferManager) {
        address adr = store.offerManager();
        if (adr == address(0)) revert _ZeroAddress();
        return BluxeOfferManager(payable(adr));
    }

    /**
      @dev seller create a Listing for an Nft they own.
      Seller must approve this contract to transfer token
    */
    function createListing(
        address nftContract,
        uint256 tokenId,
        uint256 price,
        bool auction,
        uint256 auctionEndTime
    ) public nonReentrant {
        IERC721 nft = IERC721(nftContract);

        // Interface sanity
        if (!IERC165(nftContract).supportsInterface(type(IERC721).interfaceId)) {
            revert InvalidNFT();
        }
        //  Ownership check
        if (nft.ownerOf(tokenId) != msg.sender) {
            revert NotTokenOwner(tokenId);
        }
        // Approval check (FAIL FAST)
        if (
            nft.getApproved(tokenId) != address(this) &&
            !nft.isApprovedForAll(msg.sender, address(this))
        ) {
            revert Not_Aproved();
        }
        if (price <= 0) {
            revert InvalidPrice(price);
        }
        if (auction) {
            if (auctionEndTime <= block.timestamp) {
                revert InvalidAuctionEndTime(auctionEndTime);
            }
        } else {
            if (auctionEndTime != 0) {
                revert InvalidAuctionEndTime(auctionEndTime);
            }
        }

        /// @notice transfer token to contract, List on marketplace
        nft.safeTransferFrom(msg.sender, address(this), tokenId);

        BluxeStorage.Listing memory listing = BluxeStorage.Listing({
            nftContract: nftContract,
            seller: msg.sender,
            price: price,
            tokenId: tokenId,
            active: true,
            auction: auction,
            auctionEndTime: auctionEndTime
        });

        uint256 currentListingId = nextListingId;
        nextListingId++;
        store.setListing(nftContract, tokenId, currentListingId, listing);

        require(nft.ownerOf(tokenId) == address(this), "NFT not escrowed");
        emit Listed(nftContract, msg.sender, price, tokenId, currentListingId);
    }

    /// @notice seller cancel their listing, before it's sold
    function cancelListing(uint256 listingId) public nonReentrant {
        BluxeStorage.Listing memory l = store.getListing(listingId);

        if (l.seller != msg.sender) {
            revert NotYourListing(l.tokenId);
        }

        if (!l.active) {
            revert NotActive(l.tokenId);
        }

        if (l.auction && block.timestamp < l.auctionEndTime) {
            revert BidActiveOnListing();
        }

        store.setListingActive(listingId, false);
        store.setOfferRefundable(listingId, true);
        emit OfferRefundable(l.nftContract, l.seller, l.tokenId, listingId);

        /// @notice transfer nft back to the seller, when they cancelled their listing
        try IERC721(l.nftContract).safeTransferFrom(address(this), msg.sender, l.tokenId) {
            // ok
        } catch {
            // listing already dead
            // NFT stuck but marketplace alive
        }
        /// @dev emit events
        emit Cancelled(l.nftContract, msg.sender, l.tokenId, listingId);
    }

    /** @notice Buyer purchases an active listing by sending exact price in ETH **/
    /** @dev Funds are split: royalties() -> royaltyReceiver,
     platform Fee, platform fee receipient,  remainder -> seller 
    **/
    function buyItemWithEth(uint256 listingId) external payable nonReentrant {
        BluxeStorage.Listing memory l = store.getListing(listingId);
        IERC721 nft = IERC721(l.nftContract);
        if (!IERC165(l.nftContract).supportsInterface(type(IERC721).interfaceId)) {
            revert InvalidNFT();
        }
        // Ensure the listing is valid and the seller is correct
        if (l.seller == address(0)) {
            revert ListingDoesNotExist(l.tokenId);
        }

        /// @dev Direct buy Items must be not be auction items
        if (l.auction) {
            revert ListingInAuctionModeCannotAllowedDirectBuy(l.tokenId);
        }

        /// @dev check listing is active
        if (!l.active) {
            revert NotActive(l.tokenId);
        }

        if (msg.value < l.price) revert NotEnoughETH(l.price);

        // Seller cannot buy their own listing
        if (msg.sender == l.seller) {
            revert CannotBuyOwnListing(l.seller);
        }

        /// @dev If buyer sent more than price, refund surplus
        // surplus goes to pendingWithdrawalsETH
        // this avoids issues with direct refunds
        // surplus = msg.value - l.price;
        uint256 surplus = msg.value - l.price;
        if (surplus > 0) {
            store.addPendingETH(msg.sender, surplus);
        }

        // Mark listing as inactive to prevent reentrancy double-buy
        store.setListingActive(listingId, false);

        /// @notice Mark offer Refundable (Lazy Refund) instead of refund here
        /// This allows buyers to withdraw their offers later

        store.setOfferRefundable(listingId, true);
        emit OfferRefundable(l.nftContract, l.seller, l.tokenId, listingId);

        /// Transfer NFT to buyer
        bool transferred;
        try nft.safeTransferFrom(address(this), msg.sender, l.tokenId) {
            transferred = true;
        } catch {
            /**
             * NFT stuck, but:
             * listing inactive
             * funds safe
             * buyer refunded via pendingETH
             */
        }
        if (!transferred) {
            emit NFTBlocked(l.nftContract, l.tokenId, listingId);
            store.markNFTBlocked(listingId, true);

            // refund buyer
            store.addPendingETH(msg.sender, l.price);
            return;
        }
        store.handlePayouts(l, BluxeStorage.BidTokenType.ETH);
        emit ItemPurchased(l.nftContract, l.tokenId, msg.sender, l.seller, l.price);
    }

    /** Buy With wETH (Wrapped ETH)
    @notice Buyer purchases an active listing by sending exact price in wETH
    @dev Funds are split: royalties() -> royaltyReceiver,
    platform Fee, platform fee receipient,  remainder -> seller
    */
    function buyItemWithWeth(uint256 listingId) external nonReentrant {
        BluxeStorage.Listing memory l = store.getListing(listingId);
        if (!IERC165(l.nftContract).supportsInterface(type(IERC721).interfaceId)) {
            revert InvalidNFT();
        }

        IERC721 nft = IERC721(l.nftContract);
        IERC20 weth = IERC20(store.weth());

        /// ----- Validity Checks -----
        /// Ensure the listing is valid and the seller is correct
        if (l.seller == address(0)) {
            revert ListingDoesNotExist(l.tokenId);
        }

        /// @dev Direct buy Items must be not be auction items
        if (l.auction) {
            revert ListingInAuctionModeCannotAllowedDirectBuy(l.tokenId);
        }

        /// Listing must be active
        if (!l.active) {
            revert NotActive(l.tokenId);
        }

        /// Buyer cannot buy their own NFT
        if (msg.sender == l.seller) {
            revert CannotBuyOwnListing(l.seller);
        }

        /** @dev Before giving allownce to marketplace, we should check buyer has enough wETH balance
         **/
        /// Buyer must have enough WETH
        if (weth.balanceOf(msg.sender) < l.price) {
            revert NotEnoughETH(l.price);
        }

        /// Mark listing as inactive to prevent reentrancy double-buy
        store.setListingActive(listingId, false);

        /// ----- Mark offer Refundable (Lazy Refund) instead of refund here -----
        /// All other offers on this listing will become refundable
        store.setOfferRefundable(listingId, true);
        emit OfferRefundable(l.nftContract, l.seller, l.tokenId, listingId);

        /** @dev Transfer wETH from buyer to marketplace before proceeding with sale
         **/
        weth.safeTransferFrom(msg.sender, address(this), l.price);

        /// ----- Transfer NFT to buyer -----
        bool transferred;
        try nft.safeTransferFrom(address(this), msg.sender, l.tokenId) {
            transferred = true;
        } catch {
            /**
             * NFT stuck, but:
             * listing inactive
             * funds safe
             * buyer refunded via pendingETH
             */
        }
        if (!transferred) {
            emit NFTBlocked(l.nftContract, l.tokenId, listingId);
            store.markNFTBlocked(listingId, true);

            // refund buyer
            store.addPendingWETH(msg.sender, l.price);
            return;
        }

        store.handlePayouts(l, BluxeStorage.BidTokenType.WETH);
        emit ItemPurchased(l.nftContract, l.tokenId, msg.sender, l.seller, l.price);
    }

    /// --------------- Finalize Auction ---------------
    /// @notice Finalize an auction after it has ended
    /// @dev Can only be called by the seller of the listing
    ///      This function resolves the auction via the BidContract,
    ///      stores the result for claiming later, and emits `AuctionFinalized`.
    /// @param listingId The ID of the listing/auction to finalize

    function finalizeAuction(uint256 listingId) external nonReentrant {
        BluxeStorage.Listing memory l = store.getListing(listingId);

        if (msg.sender != l.seller) revert OnlySellerCanFinalize(msg.sender);
        if (block.timestamp < l.auctionEndTime) revert AuctionNotEndedYet(listingId);

        // Resolve auction and get winner + bid info
        (address winner, uint256 amount, BluxeStorage.BidTokenType tokenType) = _bidContract()
            .resolveAuction(listingId);

        // Save info on-chain for claiming NFT later
        store.setAuctionResult(listingId, winner, amount, tokenType);

        emit AuctionFinalized(
            l.nftContract,
            l.tokenId,
            winner,
            l.seller,
            amount,
            listingId,
            tokenType
        );
    }
    /// @notice Claim the NFT after the auction has been finalized
    /// @dev Can only be called by the auction winner or seller (if no bids)
    ///      Handles NFT transfer, pending refunds in case of transfer failure,
    ///      and triggers payout distribution via BidContract
    /// @param listingId The ID of the listing/auction
    function claimAuctionNFT(uint256 listingId) external nonReentrant {
        BluxeStorage.Listing memory l = store.getListing(listingId);

        // Check if Nft was claimed already
        if (store.getAuctionClaimedStatus(listingId)) revert AlreadyClaimed(listingId);
        BluxeStorage.AuctionResult memory r = store.getAuctionResult(listingId);

        address receiver = r.winner == address(0) ? l.seller : r.winner;

        if (msg.sender != receiver) revert NotAuthorized();

        // Mark claimed BEFORE transfer to prevent double-claim
        store.markAuctionClaimed(listingId);
        bool transferred;
        // Transfer NFT
        try IERC721(l.nftContract).safeTransferFrom(address(this), receiver, l.tokenId) {
            transferred = true;
        } catch {}
        // Handle stuck NFT by marking pending refund
        if (!transferred) {
            emit NFTBlocked(l.nftContract, l.tokenId, listingId);
            store.markNFTBlocked(listingId, true);

            // refund buyer
            if (r.tokenType == BluxeStorage.BidTokenType.ETH) {
                store.addPendingETH(r.winner, r.amount);
            } else {
                store.addPendingWETH(r.winner, r.amount);
            }
            return;
        }
        // Handle payouts now (ETH / WETH / royalties / platform fee)
        _bidContract().handleBidPayouts(l, r.amount, r.tokenType);

        emit AuctionNFTClaimed(l.nftContract, l.tokenId, receiver, listingId);
    }

    /**
     * @notice Seller accepts an existing offer on their listing.
     * @dev This function ONLY updates protocol state and does NOT transfer the NFT.
     *      The NFT is claimed later by the winner via a separate lazy-claim function.
     *
     * Security:
     * - Prevents reentrancy by finalizing state before any external calls.
     * - Ensures protocol remains safe even if the NFT is malicious or reverts on transfer.
     *
     * Flow:
     * 1. Verify msg.sender is the seller.
     * 2. Resolve and consume the buyer's offer via OfferManager.
     * 3. Persist accepted offer data for lazy claiming.
     * 4. Mark listing as finalized.
     *
     * @param buyer Address of the offerer whose offer is being accepted.
     * @param listingId ID of the listing being finalized.
     */
    function acceptOffer(address buyer, uint256 listingId) external nonReentrant {
        BluxeStorage.Listing memory l = store.getListing(listingId);

        if (msg.sender != l.seller) revert OnlySellerCanFinalize(msg.sender);
        if (store.getOfferClaimedStatus(listingId)) revert AlreadyAccepted();
        BluxeStorage.AcceptedOffer memory r = store.getAcceptedOffer(listingId);
        if (r.winner != address(0) && r.amount != 0) revert AlreadyAccepted();

        /// resolve Offer and get Offerer + offer info...
        (
            address tOfferer,
            uint256 tOfAmount,
            BluxeStorage.OfferTokenType tOfTType
        ) = _offerContract().resolveOffer(buyer, listingId);
        // Save info on-chain for claiming NFT later
        store.setAcceptedOffer(listingId, tOfferer, tOfAmount, tOfTType);

        emit OfferAccepted(l.nftContract, l.seller, tOfferer, l.tokenId, tOfAmount, listingId);
    }

    /**
     * @notice Claims the NFT for an accepted offer.
     * @dev This function performs the actual NFT transfer and handles payouts.
     *      State is finalized BEFORE external calls to prevent reentrancy
     *      and to isolate malicious NFT behavior.
     *
     * Security:
     * - Marks offer as claimed before attempting NFT transfer.
     * - Uses try/catch to isolate malicious ERC721 implementations.
     * - Refunds buyer on failed NFT transfer.
     * - Ensures protocol remains live even if NFT becomes stuck.
     *
     * Flow:
     * 1. Validate offer has not been claimed.
     * 2. Validate caller is the accepted winner.
     * 3. Mark offer as claimed.
     * 4. Attempt NFT transfer via try/catch.
     * 5. If transfer fails, refund buyer and exit safely.
     * 6. If transfer succeeds, distribute payouts (royalties, fees, seller).
     *
     * @param listingId ID of the finalized listing.
     */

    function claimOfferNFT(uint256 listingId) external nonReentrant {
        BluxeStorage.Listing memory l = store.getListing(listingId);

        // Check if Nft was claimed already
        if (store.getOfferClaimedStatus(listingId)) revert AlreadyClaimed(listingId);
        BluxeStorage.AcceptedOffer memory r = store.getAcceptedOffer(listingId);
        address receiver = r.winner == address(0) ? l.seller : r.winner;

        if (msg.sender != receiver) revert NotAuthorized();
        // Mark claimed BEFORE transfer to prevent double-claim
        store.markOfferClaimed(listingId);

        bool transferred;
        try IERC721(l.nftContract).safeTransferFrom(address(this), receiver, l.tokenId) {
            transferred = true;
        } catch {}
        if (!transferred) {
            emit NFTBlocked(l.nftContract, l.tokenId, listingId);
            store.markNFTBlocked(listingId, true);

            // refund buyer
            if (r.tokenType == BluxeStorage.OfferTokenType.ETH) {
                store.addPendingETH(r.winner, r.amount);
            } else {
                store.addPendingWETH(r.winner, r.amount);
            }
            return;
        }
        // Handle payouts now (ETH / WETH / royalties / platform fee)
        _offerContract().handleOfferPayouts(l, r.amount, r.tokenType);
        emit OfferNFTClaimed(l.nftContract, l.tokenId, receiver, listingId);
    }

    /// --------------- Only Admin ---------------
    /// ------------- This section is for admin functions ---------------
    /** 
      @notice Only admin can update platform fee & platform fee receipient
    */
    function updatePlatformFee(uint96 newPlatformFee, address newPlatformReceipient) public {
        if (msg.sender != store.owner()) revert _NotOwner();

        if (newPlatformReceipient == address(0)) {
            revert BadPlatformRecipient(newPlatformReceipient);
        }
        /// @notice max 10%
        if (newPlatformFee > 1000) {
            revert priceTooHigh(newPlatformFee);
        }
        store.updatePlatformDetails(newPlatformReceipient, newPlatformFee);

        emit PlatformFeeUpdated(newPlatformFee, newPlatformReceipient);
    }

    /// ----------- Withdraw -----------
    /// *Withdraw specific amount
    // Withdraw specific amount of ETH from pendingWithdrawalsETH
    function withdrawEth(uint256 amount) external nonReentrant {
        uint256 amountAvailable = store.getPendingETH(msg.sender);

        /// @dev check for sufficient balance
        if (amount == 0 || amount > amountAvailable) {
            revert InsufficientBalance(amount);
        }

        /// @notice subtract first to prevent Re-Entrancy attacks
        // update pending withdrawals
        store.subPendingETH(msg.sender, amount);

        // send funds
        // *send specific amount
        (bool success, ) = payable(msg.sender).call{value: amount}("");
        require(success, "Transfer failed");
        emit WithdrawnETH(msg.sender, amount);
    }

    // *Withdraw specific amount
    // Withdraw specific amount of wETH from pendingWithdrawalsWETH
    function withdrawWeth(uint256 amount) external nonReentrant {
        uint256 amountAvailable = store.getPendingWETH(msg.sender);

        /// @dev check for sufficient balance
        if (amount == 0 || amount > amountAvailable) {
            revert InsufficientBalance(amount);
        }

        /// @notice subtract first to prevent Re-Entrancy attacks
        // update pending withdrawals
        store.subPendingWETH(msg.sender, amount);

        // send wETH
        SafeERC20.safeTransfer(IERC20(store.weth()), msg.sender, amount);

        emit WithdrawnWETH(msg.sender, amount);
    }

    /// @notice Withdraws the caller's entire pending ETH balance
    /// @dev Resets balance before transfer to prevent reentrancy
    function withdrawAllEth() external nonReentrant {
        uint256 amount = store.getPendingETH(msg.sender);

        if (amount == 0) revert InsufficientBalance(0);

        store.subPendingETH(msg.sender, amount);

        (bool success, ) = payable(msg.sender).call{value: amount}("");
        require(success, "ETH transfer failed");

        emit WithdrawnETH(msg.sender, amount);
    }

    /// @notice Withdraws the caller's entire pending wETH balance
    /// @dev Uses pull-payment pattern for safety
    function withdrawAllWeth() external nonReentrant {
        uint256 amount = store.getPendingWETH(msg.sender);
        if (amount == 0) revert InsufficientBalance(0);

        store.subPendingWETH(msg.sender, amount);

        SafeERC20.safeTransfer(IERC20(store.weth()), msg.sender, amount);

        emit WithdrawnWETH(msg.sender, amount);
    }

    /// @dev Admin rescue
    function rescueNFT(address nft, uint256 tokenId, address to) external {
        if (msg.sender != store.owner()) revert _NotOwner();
        if (to == address(0)) revert _ZeroAddress();

        IERC721(nft).safeTransferFrom(address(this), to, tokenId);
    }

    /// @dev to accept ETH payments
    receive() external payable {
        if (
            msg.sender != address(store.offerManager()) && msg.sender != address(store.bidManager())
        ) {
            revert("NO_DIRECT_ETH");
        }
    }

    fallback() external payable {
        if (
            msg.sender != address(store.offerManager()) && msg.sender != address(store.bidManager())
        ) {
            revert("NO_DIRECT_ETH");
        }
    }

    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes calldata
    ) external pure override returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}
