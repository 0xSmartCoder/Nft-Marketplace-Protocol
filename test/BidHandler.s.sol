//SPDX-License-idendentifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "../src/BluxeBidManager.sol";
import "../src/BluxeMarketplace.sol";
import "../src/BluxeStorage.sol";
import "../src/BluxeToken.sol";
import "../src/MockWeth.sol";

contract BidHandler is Test {
    BluxeBidManager bidContract;
    BluxeMarketplace marketplace;
    BluxeStorage storageContract;
    BluxeToken bluxe;
    FakeWETH weth;

    address[] public bidders;
    uint256 TotalListings = 10;
    uint256 public totalEthDeposited;
    uint256 public totalWethDeposited;

    constructor(
        BluxeBidManager _bidContract,
        BluxeMarketplace _marketplace,
        BluxeStorage _storage,
        BluxeToken _bluxe,
        FakeWETH _wethAddress
    ) {
        bidContract = _bidContract;
        marketplace = _marketplace;
        storageContract = _storage;
        bluxe = _bluxe;
        weth = _wethAddress;

        bidders.push(address(0xA1));
        bidders.push(address(0xA2));
        bidders.push(address(0xA3));
        bidders.push(address(0xA4));
        bidders.push(address(0xA5));

        for (uint i = 0; i < bidders.length; i++) {
            vm.deal(bidders[i], 20 ether);
        }
    }

    function _randomBidder(uint256 seed) public view returns (address) {
        return bidders[seed % bidders.length];
    }

    function ETHBid(uint256 seed, uint256 amountSeed) public {
        address bidder = _randomBidder(seed);
        uint256 listingId = seed % TotalListings;

        BluxeStorage.Listing memory l = storageContract.getListing(listingId);

        if (!l.active) return;
        if (!l.auction) return;
        if (bidder == l.seller) return;

        uint256 amount = bound(amountSeed, 0.1 ether, 1.2 ether);

        vm.startPrank(bidder);
        bidContract.placeBidEth{value: amount}(listingId);
        vm.stopPrank();
        totalEthDeposited += amount;
    }

    function WETHBid(uint256 seed, uint256 amountSeed) public {
        address bidder = _randomBidder(seed);

        uint256 listingId = seed % TotalListings;
        BluxeStorage.Listing memory l = storageContract.getListing(listingId);

        if (!l.active) return;
        if (!l.auction) return;
        if (bidder == l.seller) return;
        if (block.timestamp > l.auctionEndTime) return;

        uint256 amount = bound(amountSeed, 0.2 ether, 1.5 ether);
        vm.startPrank(bidder);
        weth.mint(bidder, amount);
        weth.approve(address(bidContract), amount);
        bidContract.placeBidWeth(listingId, amount);
        vm.stopPrank();

        totalWethDeposited += amount;
    }

    function advanceTime(uint256 seed) public {
        uint256 listingId = seed % TotalListings;
        BluxeStorage.Listing memory l = storageContract.getListing(listingId);

        if (!l.active || !l.auction) return;
        vm.warp(l.auctionEndTime + 2 days);
    }

    function bidAndFinalizeAuction(uint256 seed, uint256 amountSeed) public {
        uint256 listingId = seed % TotalListings;
        BluxeStorage.Listing memory l = storageContract.getListing(listingId);

        if (!l.active) return;
        if (!l.auction) return;
        if (block.timestamp < l.auctionEndTime) return;

        (
            address highestBidder,
            uint256 highestBid,
            BluxeStorage.BidTokenType tokentype
        ) = storageContract.getHighestBid(listingId);
        if (highestBidder == address(0)) return;

        vm.prank(l.seller);
        marketplace.finalizeAuction(listingId);

        vm.prank(address(marketplace));
        (address winner, , ) = bidContract.resolveAuction(listingId);

        vm.prank(winner);
        marketplace.claimAuctionNFT(listingId);
    }
}
