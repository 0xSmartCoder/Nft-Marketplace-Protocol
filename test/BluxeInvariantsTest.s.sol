// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "forge-std/StdInvariant.sol";
import "./MarketplaceHandler.s.sol";
import "../src/BluxeOfferManager.sol";
import "../src/BluxeBidManager.sol";
import "../src/EvilERC721.sol";
import "./OfferHandler.s.sol";
import "../src/BluxeMarketplace.sol";
import "./BidHandler.s.sol";
import "../src/BluxeStorage.sol";
import "../src/BluxeToken.sol";
import "../src/MockWeth.sol";

contract BluxeInvariantTest is StdInvariant, Test {
    BluxeMarketplace bluxeMarketplace;
    BluxeBidManager bidContract;
    BluxeStorage bluxeStorage;
    BluxeOfferManager offerContract;
    BluxeToken bluxe;
    BidHandler bidHandler;
    OfferHandler offerHandler;
    bluxeHandler marketHandler;
    FakeWETH weth;
    EvilERC721 evil;

    address public user1;
    address public user2;
    address[] public _admins;

    uint256 public TotalListings = 10;
    function setUp() public {
        _admins.push(address(11));
        _admins.push(address(12));
        _admins.push(address(13));

        bluxeStorage = new BluxeStorage(_admins);

        bidContract = new BluxeBidManager(address(bluxeStorage));
        bluxeStorage.setBidManager(address(bidContract));

        offerContract = new BluxeOfferManager(address(bluxeStorage));
        bluxeStorage.setOfferManager(address(offerContract));

        bluxeMarketplace = new BluxeMarketplace(address(bluxeStorage));
        bluxeStorage.setMarketplace(address(bluxeMarketplace));

        bluxe = new BluxeToken("", "", address(this), 500, address(this));
        weth = new FakeWETH();

        bluxeStorage.setAuthorized(address(bluxeMarketplace), true);
        bluxeStorage.setAuthorized(address(bidContract), true);
        bluxeStorage.setWeth(address(weth));

        // evil = new EvilERC721(address(bluxeMarketplace));
        // evil.mint(100);
        // evil.setApprovalForAll(address(bluxeMarketplace), true);

        for (uint i = 0; i < 12; i++) {
            bluxe.mint("", "", "", address(this));
            bluxe.approve(address(bluxeMarketplace), i);
        }

        //     bluxeMarketplace.createListing(
        // address(evil),
        // 100,
        // 1 ether,
        // true, // auction
        // block.timestamp + 1 days
        // );
        for (uint i = 0; i < 10; i++) {
            /// Even Listings for `Auction Mode`
            if (i % 2 == 0) {
                bluxeMarketplace.createListing(address(bluxe), i, 1 ether, true, 1768893419);
            }
        }

        for (uint i = 0; i < 10; i++) {
            /// Odd Listings for `Simple Listing`
            if (i % 2 != 0) {
                bluxeMarketplace.createListing(address(bluxe), i, 1 ether, false, 0);
            }
        }

        marketHandler = new bluxeHandler(bluxeMarketplace, bluxeStorage, bluxe, weth);

        offerHandler = new OfferHandler(
            bidContract,
            offerContract,
            bluxeMarketplace,
            bluxeStorage,
            bluxe,
            weth
        );

        bidHandler = new BidHandler(bidContract, bluxeMarketplace, bluxeStorage, bluxe, weth);

        targetContract(address(marketHandler));
        targetContract(address(bidHandler));
        targetContract(address(offerHandler));

        user1 = address(0xac);
        user2 = address(0xce);

        vm.deal(user1, 10 ether);
        vm.deal(user2, 10 ether);
    }

    function invariant_listingCannotBeActiveAfterBuy() public {
        for (uint i = 0; i < TotalListings; i++) {
            BluxeStorage.Listing memory l = bluxeStorage.getListing(i);

            // if Nft not is Escrow
            if (bluxe.ownerOf(l.tokenId) != address(bluxeMarketplace)) {
                assertEq(l.active, false);
            }
        }
    }
    function invariant_EscrowConsistency() public {
        for (uint i = 0; i < TotalListings; i++) {
            BluxeStorage.Listing memory l = bluxeStorage.getListing(i);
            bool isClaimed = bluxeStorage.getAuctionClaimedStatus(i);
            if (l.active && !isClaimed) {
                assertEq(IERC721(l.nftContract).ownerOf(l.tokenId), address(bluxeMarketplace));
            } else {
                assertTrue(bluxe.ownerOf(l.tokenId) != address(bluxeMarketplace), "Not In Escrow");
            }
        }
    }

    function invariant_OwnerIsNotHighestBidder() public {
        for (uint256 i = 0; i < TotalListings; i++) {
            BluxeStorage.Listing memory l = bluxeStorage.getListing(i);
            (address highestBidder, , ) = bluxeStorage.getHighestBid(i);
            if (highestBidder != address(0)) {
                assertTrue(highestBidder != l.seller, "Owner became highest bidder");
            }
        }
    }
    function invariant_AuctionFinalizedCorrectly() public {
        for (uint256 i = 0; i < TotalListings; i++) {
            BluxeStorage.Listing memory l = bluxeStorage.getListing(i);
            (address highestBidder, , ) = bluxeStorage.getHighestBid(i);
            bool isClaimed = bluxeStorage.getAuctionClaimedStatus(i);
            if (!l.active && l.auction && isClaimed) {
                address owner = bluxe.ownerOf(l.tokenId);
                assertTrue(owner != l.seller);
                assertTrue(owner != address(0));
                bool isValid = false;

                /// these are `Same Bidder` addresses that are in our `handler`
                address[5] memory bidders = [
                    address(0xA1),
                    address(0xA2),
                    address(0xA3),
                    address(0xA4),
                    address(0xA5)
                ];

                for (uint256 j = 0; j < bidders.length; j++) {
                    if (owner == bidders[j]) {
                        isValid = true;
                        break;
                    }
                }
                assertTrue(isValid);
            }
        }
    }

    function invariant_OfferRefundableIfListingCancelled() public {
        for (uint i = 0; i < TotalListings; i++) {
            BluxeStorage.Listing memory l = bluxeStorage.getListing(i);
            if (l.seller != address(0) && !l.active && !l.auction) {
                assertEq(bluxeStorage.isOfferRefundable(i), true);
            }
        }
    }

    function invariant_OfferAcceptedListingShouldBeNotActiveMore() public {
        for (uint i = 0; i < TotalListings; i++) {
            BluxeStorage.AcceptedOffer memory a = bluxeStorage.getAcceptedOffer(i);
            BluxeStorage.Listing memory l = bluxeStorage.getListing(i);
            if (a.amount > 0 && a.winner != address(0)) {
                assertEq(l.active, false);
                // other offer are refundable
                assertEq(bluxeStorage.isOfferRefundable(i), true);
            }
        }
    }

    function invariant_NFTClaimedAtMostONCE() public {
        for (uint i = 0; i < TotalListings; i++) {
            bool isClaimed = bluxeStorage.getOfferClaimedStatus(i);
            BluxeStorage.Listing memory l = bluxeStorage.getListing(i);
            BluxeStorage.AcceptedOffer memory r = bluxeStorage.getAcceptedOffer(i);
            if (isClaimed) {
                assertEq(l.active, false);
                // other offer are refundable
                assertEq(bluxeStorage.isOfferRefundable(i), true);
                vm.expectRevert(AlreadyClaimed.selector);
                bluxeMarketplace.claimOfferNFT(i);
                bool nftLeft;
                try IERC721(l.nftContract).ownerOf(l.tokenId) returns (address o) {
                    nftLeft = (o != address(bluxeMarketplace));
                } catch {}
                uint buyerRefund = bluxeStorage.getPendingETH(r.winner) +
                    bluxeStorage.getPendingWETH(r.winner);

                assertTrue(nftLeft || buyerRefund > 0.01 ether);
            }
        }
    }
}
