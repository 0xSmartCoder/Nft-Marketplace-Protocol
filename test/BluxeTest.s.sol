// SPDX License Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "../src/BluxeBidManager.sol";
import {BluxeStorage} from "../src/BluxeStorage.sol";
import {BluxeMarketplace} from "../src/BluxeMarketplace.sol";
import {BluxeToken} from "../src/BluxeToken.sol";
import {BluxeOfferManager} from "../src/BluxeOfferManager.sol";
import {FakeWETH} from "../src/MockWeth.sol";
import {console} from "lib/forge-std/src/console.sol";

contract BluxeTest is Test, IERC721Receiver {
    BluxeStorage public bluxeStorage;
    BluxeBidManager public bidContract;
    BluxeMarketplace public bluxeMarketplace;
    BluxeOfferManager public offerContract;
    BluxeToken public bluxe;
    FakeWETH public weth;

    address public user1;
    address public user2;
    address[] public _admins;

    function setUp() public {
        _admins.push(address(11));
        _admins.push(address(12));
        _admins.push(address(13));

        bluxe = new BluxeToken("", "", msg.sender, 500, msg.sender);

        weth = new FakeWETH();

        bluxeStorage = new BluxeStorage(_admins);
        // 0.075 + 0.0675

        bidContract = new BluxeBidManager(address(bluxeStorage));
        bluxeStorage.setBidManager(address(bidContract));

        offerContract = new BluxeOfferManager(address(bluxeStorage));
        bluxeStorage.setOfferManager(address(offerContract));

        bluxeMarketplace = new BluxeMarketplace(address(bluxeStorage));
        bluxeStorage.setMarketplace(address(bluxeMarketplace));

        bluxeStorage.setAuthorized(address(bluxeMarketplace), true);
        bluxeStorage.setAuthorized(address(bidContract), true);
        bluxeStorage.setAuthorized(address(offerContract), true);

        bluxeStorage.setWeth(address(weth));

        bluxe.mint("", "", "", address(this));
        bluxeStorage.updatePlatformDetails(msg.sender, 450);

        user1 = address(0xA1);
        user2 = address(0xB2);

        vm.deal(user1, 10 ether);
        vm.deal(user2, 10 ether);

        bluxe.approve(address(bluxeMarketplace), 0);
        bluxeMarketplace.createListing(address(bluxe), 0, 1 ether, false, 0);
    }

    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) external pure override returns (bytes4) {
        return this.onERC721Received.selector;
    }

    /****************************************************************** 
    --------------------- Bluxe Marketplace Test Functions ------------
    *******************************************************************/

    function testCreateListing() public {
        bluxe.mint("", "", "", address(this));
        bluxe.approve(address(bluxeMarketplace), 1);

        /* (1️) FAIL: Non-owner tries to list */
        vm.prank(msg.sender);
        vm.deal(msg.sender, 5 ether);
        vm.expectRevert();
        bluxeMarketplace.createListing(address(bluxe), 1, 1 ether, false, 0);

        /* (2) FAIL: Try to list with invalid price */
        vm.expectRevert();
        bluxeMarketplace.createListing(address(bluxe), 1, 0 ether, false, 0);

        /* (3) CHECK:List & Owner */
        bluxeMarketplace.createListing(address(bluxe), 1, 1 ether, false, 0);
        /// check owner of Nft
        assertEq(bluxe.ownerOf(0), address(bluxeMarketplace));
    }

    function testCancelListing() public {
        /* (1) FAIL: Non-owner tries to cancel  */
        vm.prank(msg.sender);
        vm.expectRevert();
        bluxeMarketplace.cancelListing(0);

        /* (2) FAIL: Try to cancel non-active listing */
        // let's mint new NFT,
        bluxe.mint("", "", "", address(this)); // this NFT is not Listed on Marketplace
        vm.expectRevert();
        bluxeMarketplace.cancelListing(1);

        /* (3) CHECK: Listing status & Owner */
        bluxeMarketplace.cancelListing(0);
        BluxeStorage.Listing memory listing = bluxeStorage.getListing(0);
        assertEq(listing.active, false);
        assertEq(bluxe.ownerOf(0), address(this));
    }

    function testBuyETHItem() public {
        address buyer = address(0xcde54);
        address buyerWithZeroETH = address(0xcd4eb);
        vm.deal(buyer, 6 ether);
        vm.deal(buyerWithZeroETH, 0 ether);

        /* (1) FAIL: Nft not in Escrow */
        bluxe.mint("", "", "", address(this));
        vm.startPrank(buyer);
        vm.expectRevert();
        bluxeMarketplace.buyItemWithEth{value: 1 ether}(1);
        vm.stopPrank();

        /* (2) FAIL: Listing is not-active */
        /*----- List Nft(1), So Nft(1) -> `active` ----- */
        bluxe.approve(address(bluxeMarketplace), 1);
        bluxeMarketplace.createListing(address(bluxe), 1, 2 ether, false, 0);
        /* ----- Cancel Immediately, So Nft(1) -> `non-active` ----- */
        bluxeMarketplace.cancelListing(1);

        vm.startPrank(buyer);
        vm.expectRevert();
        bluxeMarketplace.buyItemWithEth{value: 1 ether}(1);
        vm.stopPrank();

        /* (3) FAIL: Not enough ETH for NFT's price */

        vm.startPrank(buyerWithZeroETH);
        vm.expectRevert();
        bluxeMarketplace.buyItemWithEth{value: 0 ether}(0);
        vm.stopPrank();

        /* (4) FAIL: Seller cannot buy their own listing */
        vm.prank(address(this));
        vm.expectRevert();
        bluxeMarketplace.buyItemWithEth{value: 1 ether}(0);

        vm.prank(buyer);
        /* (5) BUY & CHECK: Buyer sent more than price ? */
        bluxeMarketplace.buyItemWithEth{value: 1.2 ether}(0);
        assertEq(bluxeStorage.getPendingETH(address(buyer)), 0.2 ether);

        /// Offer Refundable should be -> true & listing.active -> false
        assertEq(bluxeStorage.isOfferRefundable(0), true);
        assertEq(bluxeStorage.getListing(0).active, false);

        /** ------------ Royalties & Fees (Calculation) ------------ */
        // Platform fee = salePrice * platFormFeeBps / 10000 = 0.045 eth
        // Royalty = salePrice * royaltyBps / 10000 = 0.05 eth
        // Seller = salePrice - platformFee - royalty = 0.95225 eth
        /** ---- Royalty reciever & Platfrom fee reciepient is msg.sender */
        assertEq(bluxeStorage.getPendingETH(msg.sender), 0.045 ether + 0.05 ether);

        /* (6) OWNER */
        assertEq(bluxe.ownerOf(0), address(buyer));
    }

    function testBuyWETHItem() public {
        address buyer = address(0xcde54);
        address buyerWithZeroETH = address(0xcd4eb);
        weth.mint(buyer, 5 ether);

        /* (1) FAIL: Nft not in Escrow */
        bluxe.mint("", "", "", address(this));
        vm.startPrank(buyer);
        weth.approve(address(bluxeMarketplace), 1 ether);
        vm.expectRevert();
        bluxeMarketplace.buyItemWithWeth(1);
        vm.stopPrank();

        /* (2) FAIL: Listing is not-active */
        /*----- List Nft(1), So Nft(1) -> `active` ----- */
        bluxe.approve(address(bluxeMarketplace), 1);
        bluxeMarketplace.createListing(address(bluxe), 1, 2 ether, false, 0);
        /* ----- Cancel Immediately, So Nft(1) -> `non-active` ----- */
        bluxeMarketplace.cancelListing(1);

        vm.startPrank(buyer);
        weth.approve(address(bluxeMarketplace), 1 ether);
        vm.expectRevert();
        bluxeMarketplace.buyItemWithWeth(1);
        vm.stopPrank();

        /* (3) FAIL: Not enough WETH for NFT's price */

        weth.mint(buyerWithZeroETH, 2 ether);
        vm.startPrank(buyerWithZeroETH);
        weth.approve(address(bluxeMarketplace), 0.5 ether);
        vm.expectRevert();
        bluxeMarketplace.buyItemWithWeth(0);
        vm.stopPrank();

        /* (4) FAIL: Seller cannot buy their own listing */
        vm.startPrank(address(this));
        weth.approve(address(bluxeMarketplace), 1.5 ether);
        vm.expectRevert();
        bluxeMarketplace.buyItemWithWeth(0);
        vm.stopPrank();

        vm.startPrank(buyer);
        /* (5) BUY & CHECK: Buyer sent more than price ? */
        weth.approve(address(bluxeMarketplace), 2 ether);
        bluxeMarketplace.buyItemWithWeth(0);
        vm.stopPrank();

        /// Offer Refundable should be -> true & listing.active -> false
        assertEq(bluxeStorage.isOfferRefundable(0), true);
        assertEq(bluxeStorage.getListing(0).active, false);

        /** ------------ Royalties & Fees (Calculation) ------------ */
        // Platform fee = salePrice * platFormFeeBps / 10000 = 0.045 eth
        // Royalty = salePrice * royaltyBps / 10000 = 0.05 eth
        // Seller = salePrice - platformFee - royalty = 0.95225 eth
        /** ---- Royalty reciever & Platfrom fee reciepient is msg.sender */
        assertEq(bluxeStorage.getPendingWETH(msg.sender), 0.045 ether + 0.05 ether);

        /* (6) OWNER */
        assertEq(bluxe.ownerOf(0), address(buyer));
    }

    /****************************************************************** 
    --------------------- Bluxe Bid Manager Test Functions ------------
    *******************************************************************/

    function testPlaceWETHBid() public {
        /* (1) Mint, Approve & List*/
        bluxe.mint("", "", "", address(this));
        bluxe.approve(address(bluxeMarketplace), 1);
        bluxeMarketplace.createListing(address(bluxe), 1, 1 ether, true, 1768889513);
        weth.mint(user1, 5 ether);

        /* (2) Revert: listing is not in Auction Mode */
        vm.startPrank(user1);
        weth.approve(address(bidContract), 1.2 ether);
        vm.expectRevert();
        bidContract.placeBidWeth(0, 1 ether);
        vm.stopPrank();

        /* (3) Revert: Seller can try to Bid on their own Listing */
        weth.mint(address(this), 4 ether);
        weth.approve(address(bidContract), 1.2 ether);
        vm.expectRevert();
        bidContract.placeBidWeth(1, 1.2 ether);

        /* (4) Revert: Auction Time Ended */
        vm.startPrank(user1);
        weth.approve(address(bidContract), 1.2 ether);
        vm.warp(1768889513 + 1);
        vm.expectRevert();
        bidContract.placeBidWeth(1, 1.2 ether);
        vm.warp(1768889513 - 1 days);
        vm.stopPrank();

        /* (5) Revert: Listing not active */
        bluxe.mint("", "", "", address(this));
        vm.startPrank(user1);
        weth.approve(address(bidContract), 1.2 ether);
        vm.expectRevert();
        bidContract.placeBidWeth(2, 1.2 ether);
        vm.stopPrank();

        /* (6) Revert: Bid Weth `Same Bidder`*/
        vm.startPrank(user1);
        weth.approve(address(bidContract), 1.05 ether);
        bidContract.placeBidWeth(1, 1.05 ether);

        /* (7) Revert: Same bidder try to Bid again with `Different Token` */
        vm.expectRevert();
        bidContract.placeBidEth{value: 1.05 ether}(1);

        /* (8) Revert: Must increase your ownBid */
        weth.approve(address(bidContract), 1.05 ether);
        vm.expectRevert();
        bidContract.placeBidWeth(1, 1.05 ether);

        /* (9) Bid: Check HighestBid */
        weth.approve(address(bidContract), 1.1025 ether);
        bidContract.placeBidWeth(1, 1.1025 ether);
        (address highestBidder, uint256 highestBidAmount, ) = bluxeStorage.getHighestBid(1);
        assertEq(highestBidder, user1);
        assertEq(highestBidAmount, 1.1025 ether);

        /* (9) Auction time extension increase */
        vm.warp(bluxeStorage.getListing(1).auctionEndTime - (5 minutes - 1));
        weth.approve(address(bidContract), 1.157625 ether);
        bidContract.placeBidWeth(1, 1.157625 ether);
        BluxeStorage.Listing memory l = bluxeStorage.getListing(1);
        assertEq(l.auctionEndTime, 1768889813);
        vm.stopPrank();

        /* (10) New Bidder */
        weth.mint(user2, 5 ether);
        vm.startPrank(user2);
        weth.approve(address(bidContract), 1.21550625 ether);
        bidContract.placeBidWeth(1, 1.21550625 ether);
        (address _highestBidder, uint256 highestBidderAmount, ) = bluxeStorage.getHighestBid(1);
        assertEq(_highestBidder, user2);
        assertEq(highestBidderAmount, 1.21550625 ether);
    }

    function testFinalizeAuction() public {
        /* (1) Mint, Approve & Create Auction Listing */
        bluxe.mint("", "", "", address(this));
        bluxe.approve(address(bluxeMarketplace), 1);
        bluxeMarketplace.createListing(address(bluxe), 1, 1 ether, true, block.timestamp + 1 days);
        assertEq(bluxe.ownerOf(1), address(bluxeMarketplace));

        /* (2) Revert: Non-seller cannot finalize */
        vm.startPrank(user1);
        vm.expectRevert();
        bluxeMarketplace.finalizeAuction(1);
        vm.stopPrank();

        /* (3) Revert: Auction not ended yet */
        vm.expectRevert();
        bluxeMarketplace.finalizeAuction(1);

        /* (4) Place WETH Bid */
        weth.mint(user1, 5 ether);
        vm.startPrank(user1);
        weth.approve(address(bidContract), 1.2 ether);
        bidContract.placeBidWeth(1, 1.2 ether);
        vm.stopPrank();

        /* (5) Warp time after auction end */
        vm.warp(block.timestamp + 5 days);

        /* (6) Finalize Auction */
        bluxeMarketplace.finalizeAuction(1);

        /* (7) Revert: Unknown user try to claim Nft*/
        address unknownPerson = address(0xcca);
        vm.prank(unknownPerson);
        vm.expectRevert();
        bluxeMarketplace.claimAuctionNFT(1);

        /* (8) Claim & Try to reclaim */
        vm.prank(user1);
        bluxeMarketplace.claimAuctionNFT(1);
        vm.expectRevert();
        bluxeMarketplace.claimAuctionNFT(1);

        /* (9) Assert: NFT transferred to winner */
        assertEq(bluxe.ownerOf(1), user1);

        /* (10) Assert: Listing inactive */
        BluxeStorage.Listing memory l = bluxeStorage.getListing(1);
        assertEq(l.active, false);

        /* (11) Assert: Highest bid reset */
        (address bidder, uint256 amount, BluxeStorage.BidTokenType t) = bluxeStorage.getHighestBid(
            1
        );

        assertEq(bidder, address(0));
        assertEq(amount, 0);
        assertEq(uint256(t), uint256(BluxeStorage.BidTokenType.NONE));

        /* (12) Assert: Seller got pending WETH */
        uint256 sellerPending = bluxeStorage.getPendingWETH(address(this));
        assertEq(bluxeStorage.getPendingWETH(msg.sender), 0.114 ether);
        assertEq(sellerPending, 1.086 ether);
    }

    /****************************************************************** 
    --------------------- Bluxe Offer Manager Test Functions ------------
    *******************************************************************/

    function testOfferWeth() public {
        // we don't need to mint & list again cuz we have `0` Id
        weth.mint(address(this), 4 ether);
        weth.mint(user1, 4 ether);

        /* (1) Revert: listing not active */
        bluxe.mint("", "", "", address(this));
        bluxe.approve(address(bluxeMarketplace), 1);
        bluxeMarketplace.createListing(address(bluxe), 1, 0.2 ether, false, 0);
        bluxeMarketplace.cancelListing(1);
        vm.startPrank(user1);
        weth.approve(address(offerContract), 0.2 ether);
        vm.expectRevert();
        offerContract.makeOfferWeth(1, 0.2 ether);
        vm.stopPrank();

        /* (2) Revert: offer 0 amount */
        vm.startPrank(user1);
        vm.expectRevert();
        offerContract.makeOfferWeth(0, 0 ether);
        vm.stopPrank();

        /* (3) Revert: Cannot make offer an auction listing */
        bluxe.approve(address(bluxeMarketplace), 1);
        bluxeMarketplace.createListing(
            address(bluxe),
            1,
            0.2 ether,
            true,
            block.timestamp + 1 days
        );
        vm.startPrank(user1);
        weth.approve(address(offerContract), 0.2 ether);
        vm.expectRevert();
        offerContract.makeOfferWeth(2, 0.2 ether);
        vm.stopPrank();

        /* (4) Revert: Seller cannot make offer on their own listing */
        weth.approve(address(offerContract), 0.2 ether);
        vm.expectRevert();
        offerContract.makeOfferWeth(0, 0.2 ether);

        /* (5) Offer: top offerer try to reduce their offer */
        vm.startPrank(user1);
        weth.approve(address(offerContract), 0.2 ether);
        offerContract.makeOfferWeth(0, 0.2 ether);
        vm.expectRevert();
        offerContract.makeOfferWeth(0, 0.19 ether);
        vm.stopPrank();

        /* (6) Verify states are working correctly */
        weth.mint(user2, 4 ether);
        vm.startPrank(user2);
        weth.approve(address(offerContract), 0.21 ether);
        offerContract.makeOfferWeth(0, 0.21 ether);
        vm.stopPrank();
        (address topOfferer, uint256 topOffererAmount, ) = bluxeStorage.getTopOffer(0);
        assertEq(topOfferer, user2);
        assertEq(topOffererAmount, 0.21 ether);

        // user1 offer
        (uint offerAmount, ) = bluxeStorage.getOffer(0, user1);
        assertEq(offerAmount, 0.20 ether);

        // user2 offer
        (uint _offerAmount, ) = bluxeStorage.getOffer(0, user2);
        assertEq(_offerAmount, 0.21 ether);

        /// new top Offer
        weth.mint(address(0xaca), 3 ether);
        vm.startPrank(address(0xaca));
        weth.approve(address(offerContract), 0.26 ether);
        offerContract.makeOfferWeth(0, 0.26 ether);
        vm.stopPrank();
        (address _topOfferer, uint256 _topOffererAmount, ) = bluxeStorage.getTopOffer(0);
        assertEq(_topOfferer, address(0xaca));
        assertEq(_topOffererAmount, 0.26 ether);
    }

    function testOfferEth() public {
        // we also don't need to mint & list again cuz we have `0` Id

        /* (1) Revert: listing not active */
        bluxe.mint("", "", "", address(this));
        bluxe.approve(address(bluxeMarketplace), 1);
        bluxeMarketplace.createListing(address(bluxe), 1, 0.2 ether, false, 0);
        bluxeMarketplace.cancelListing(1);
        vm.startPrank(user1);
        vm.expectRevert();
        offerContract.makeOfferEth{value: 0.2 ether}(1);
        vm.stopPrank();

        /* (2) Revert: offer 0 amount */
        vm.startPrank(user1);
        vm.expectRevert();
        offerContract.makeOfferEth{value: 0 ether}(0);
        vm.stopPrank();

        /* (3) Revert: Cannot make offer an auction listing */
        bluxe.approve(address(bluxeMarketplace), 1);
        bluxeMarketplace.createListing(
            address(bluxe),
            1,
            0.2 ether,
            true,
            block.timestamp + 1 days
        );
        vm.startPrank(user1);
        vm.expectRevert();
        offerContract.makeOfferEth{value: 0.2 ether}(2);
        vm.stopPrank();

        /* (4) Revert: Seller cannot make offer on their own listing */
        weth.approve(address(offerContract), 0.2 ether);
        vm.expectRevert();
        offerContract.makeOfferEth{value: 0.2 ether}(0);

        /* (5) Offer: top offerer try to reduce their offer */
        vm.startPrank(user1);
        offerContract.makeOfferEth{value: 0.21 ether}(0);
        vm.expectRevert();
        offerContract.makeOfferEth{value: 0.20 ether}(0);
        vm.stopPrank();

        /* (6) Verify states are working correctly */
        vm.startPrank(user2);
        offerContract.makeOfferEth{value: 0.25 ether}(0);
        vm.stopPrank();
        (
            address topOfferer,
            uint256 topOffererAmount,
            BluxeStorage.OfferTokenType tokenType
        ) = bluxeStorage.getTopOffer(0);
        assertEq(topOfferer, user2);
        assertEq(topOffererAmount, 0.25 ether);
        assertEq(uint(tokenType), uint(BluxeStorage.OfferTokenType.ETH));

        // user1 offer
        (uint offerAmount, ) = bluxeStorage.getOffer(0, user1);
        assertEq(offerAmount, 0.21 ether);

        // user2 offer
        (uint _offerAmount, ) = bluxeStorage.getOffer(0, user2);
        assertEq(_offerAmount, 0.25 ether);

        /// new top Offer
        vm.startPrank(address(0xaca));
        vm.deal(address(0xaca), 1 ether);
        offerContract.makeOfferEth{value: 0.33 ether}(0);
        vm.stopPrank();
        (address _topOfferer, uint256 _topOffererAmount, ) = bluxeStorage.getTopOffer(0);
        assertEq(_topOfferer, address(0xaca));
        assertEq(_topOffererAmount, 0.33 ether);
    }

    function testAcceptOffer() public {
        // Place offers
        weth.mint(address(0xaca), 3 ether);
        vm.deal(address(0xaca), 3 ether);
        vm.prank(user1);
        offerContract.makeOfferEth{value: 0.9 ether}(0);
        (address topOfferer, , ) = bluxeStorage.getTopOffer(0);
        assertEq(topOfferer, user1);

        vm.prank(user2);
        offerContract.makeOfferEth{value: 1.5 ether}(0);
        (address _topOfferer, , ) = bluxeStorage.getTopOffer(0);
        assertEq(_topOfferer, user2);

        vm.startPrank(address(0xaca));
        weth.approve(address(offerContract), 1.9 ether);
        offerContract.makeOfferWeth(0, 1.9 ether);
        (address __topOfferer, , ) = bluxeStorage.getTopOffer(0);
        assertEq(__topOfferer, address(0xaca));
        vm.stopPrank();

        /* (1) Revert: Only seller can call */
        vm.prank(user1);
        vm.expectRevert();
        bluxeMarketplace.acceptOffer(user2, 0);

        /* (2) Revert: Non active listing */
        bluxe.mint("", "", "", address(this));
        bluxe.approve(address(bluxeMarketplace), 1);
        bluxeMarketplace.createListing(address(bluxe), 1, 0.2 ether, false, 0);
        bluxeMarketplace.cancelListing(1);
        vm.expectRevert();
        bluxeMarketplace.acceptOffer(user2, 1);

        /* (3) Revert: Selected buyer have 0 offer */
        vm.expectRevert();
        bluxeMarketplace.acceptOffer(address(0xacac), 0);

        /* (4) Accept Offer & check states */
        bluxeMarketplace.acceptOffer(user2, 0);
        (uint256 amount, ) = bluxeStorage.getOffer(0, user2);
        assertEq(amount, 0);

        BluxeStorage.Listing memory l = bluxeStorage.getListing(0);
        assertEq(l.active, false);

        bool isR = bluxeStorage.isOfferRefundable(0); //is-Refundable
        assertEq(isR, true);

        BluxeStorage.AcceptedOffer memory a = bluxeStorage.getAcceptedOffer(0);
        assertEq(a.winner, user2);
        assertEq(a.amount, 1.5 ether);
        assertEq(uint(a.tokenType), uint(BluxeStorage.OfferTokenType.ETH));

        // offers reset after seller accaept an offer
        (address TopOfferer, uint topOfAmount, BluxeStorage.OfferTokenType tOfTType) = bluxeStorage
            .getTopOffer(0);
        assertEq(TopOfferer, address(0));
        assertEq(topOfAmount, 0);

        // other offerers can now refund their offers
        assertEq(bluxeStorage.isOfferRefundable(0), true);
        vm.prank(address(0xaca));
        offerContract.withdrawRefundableOffer(0);
        assertEq(bluxeStorage.getPendingWETH(address(0xaca)), 1.9 ether);

        /* (5) Claim Nft */
        /// revert unkonwn user try to call
        vm.prank(user1);
        vm.expectRevert();
        bluxeMarketplace.claimOfferNFT(0);

        // claim and try to re-claim...
        vm.startPrank(user2);
        bluxeMarketplace.claimOfferNFT(0);
        vm.expectRevert();
        bluxeMarketplace.claimOfferNFT(0);
        vm.stopPrank();

        // verify states after claim()
        assertEq(bluxe.ownerOf(0), user2);

        (uint isAmount, ) = bluxeStorage.getOffer(0, user1);
        assertEq(isAmount, 0.9 ether);

        // user1 now refund his offer
        vm.prank(user1);
        offerContract.withdrawRefundableOffer(0);
        /// user 1 offer's 0.9 eth
        assertEq(bluxeStorage.getPendingETH(user1), 0.9 ether);

        (uint _isAmount, ) = bluxeStorage.getOffer(0, user1);
        assertEq(_isAmount, 0);
        bool isOferrer = bluxeStorage.getIsOfferer(0, user1);
        assertEq(isOferrer, false);
        // try to claim again
        vm.prank(user1);
        vm.expectRevert();
        offerContract.withdrawRefundableOffer(0);

        /* (6) Verify royalty calculation... */
        // royalty + platformFee credit to -> msg.sender
        (uint am) = bluxeStorage.getPendingETH(msg.sender);
        assertEq(am, 0.1425 ether);
        // buyer seller credit -> address(this)
        (uint _am) = bluxeStorage.getPendingETH(address(this));
        assertEq(_am, 1.3575 ether);
    }
}
