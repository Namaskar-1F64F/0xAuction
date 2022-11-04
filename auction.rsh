/* eslint-disable no-self-compare */
/* eslint-disable no-array-constructor */
/* eslint-disable no-use-before-define */
/* eslint-disable eqeqeq */
/* eslint-disable no-unused-vars */
/* eslint-disable no-undef */
'reach 0.1'

const state = Bytes(20)
const DEADLINE = 20
const amt = 1
const optToken = 1000000
export const main = Reach.App(() => {
	const Seller = Participant('Seller', {
		getAuction: Object({
			id: UInt,
			tokenId: Token,
			deadline: UInt,
			price: UInt,
			owner: Address,
			title: Bytes(20),
			description: Bytes(80),
			Admin: Address,
		}),
	})

	const endResponse = Struct([
		['id', UInt],
		['blockEnded', UInt],
		['lastBid', UInt],
	])

	const Bidder = API('Bidder', {
		bid: Fun([UInt], Tuple(Address, UInt)),
		optIn: Fun([], Bool),
	})

	const Auctioneer = API('Auctioneer', {
		stopAuction: Fun([], endResponse),
		acceptSale: Fun([], Bool),
		rejectSale: Fun([], Bool),
	})

	const Auction = Events({
		log: [state, UInt, UInt],
		created: [UInt, Contract, UInt, Address, Bytes(20), Bytes(80), UInt, Token],
		outcome: [state, Bytes(20), UInt, Address, Address, Token]
	})

	const AuctionView = View('AuctionView', {
		isRunning: Bool,
		awaitingConfirmation: Bool,
	})

	init()

	Seller.only(() => {
		const { tokenId, ...auctionInfo } = declassify(interact.getAuction)
	})
	Seller.publish(tokenId, auctionInfo)
	commit()
	Seller.pay([[amt, tokenId]])

	Auction.created(
		auctionInfo.id,
		getContract(),
		thisConsensusTime(),
		auctionInfo.owner,
		auctionInfo.title,
		auctionInfo.description,
		auctionInfo.price,
		tokenId
	)

	const [timeRemaining, keepGoing] = makeDeadline(auctionInfo.deadline)

	const [keepBidding, highestBidder, lastPrice, isFirstBid] = parallelReduce([
		true,
		Seller,
		0,
		true,
	])
		.invariant(balance(tokenId) == amt)
		.invariant(balance() == (isFirstBid ? 0 : lastPrice))
		.while(keepGoing() && keepBidding)
		.define(() => {
			AuctionView.isRunning.set(keepBidding && keepGoing())
		})
		.api_(Bidder.bid, (bid) => {
			check(bid > lastPrice, 'Your bid is too low, please try again')
			return [
				bid,
				(notify) => {
					notify([highestBidder, lastPrice])
					if (!isFirstBid) transfer(lastPrice).to(highestBidder)
					const who = this
					Auction.log(state.pad('bidSuccess'), auctionInfo.id, bid)
					return [keepBidding, who, bid, false]
				},
			]
		})
		.api_(Bidder.optIn, () => {
			return [
				optToken,
				(notify) => {
					const adminDue = (optToken / 100) * 90
					const sellerDue = (optToken / 100) * 10
					if (balance() >= adminDue) transfer(adminDue).to(auctionInfo.Admin)
					if (balance() >= sellerDue) transfer(sellerDue).to(Seller)
					notify(true)
					return [keepBidding, highestBidder, lastPrice, isFirstBid]
				},
			]
		})
		.api(
			Auctioneer.stopAuction,
			() => {
				check(this == Seller, 'You are not the Seller')
			},
			() => 0,
			(notify) => {
				Auction.log(state.pad('endSuccess'), auctionInfo.id, lastPrice)
				const response = endResponse.fromObject({
					id: auctionInfo.id,
					blockEnded: thisConsensusTime(),
					lastBid: lastPrice,
				})
				notify(response)
				return [false, highestBidder, lastPrice, isFirstBid]
			}
		)
		.timeout(timeRemaining(), () => {
			Seller.publish()
			return [keepBidding, highestBidder, lastPrice, isFirstBid]
		})

	Auction.log(state.pad('down'), auctionInfo.id, lastPrice)

	const awaitingDecision = parallelReduce(true)
		.define(() => {
			AuctionView.awaitingConfirmation.set(awaitingDecision)
		})
		.invariant(balance(tokenId) == balance(tokenId))
		.while(awaitingDecision)
		.api(
			Auctioneer.acceptSale,
			() => {
				check(this == Seller, 'You are not the Seller')
			},
			() => 0,
			(notify) => {
				transfer(balance(tokenId), tokenId).to(highestBidder)
				transfer(balance()).to(Seller)
				notify(true)
				Auction.outcome(state.pad('accepted'), auctionInfo.title, lastPrice, Seller, highestBidder, tokenId)
				return false
			}
		)
		.api(
			Auctioneer.rejectSale,
			() => {
				check(this == Seller, 'You are not the Seller')
			},
			() => 0,
			(notify) => {
				transfer(balance(tokenId), tokenId).to(Seller)
				transfer(balance()).to(highestBidder)
				notify(false)
				Auction.outcome(state.pad('rejected'), auctionInfo.title, lastPrice, Seller, highestBidder, tokenId)
				return false
			}
		)
		.timeout(relativeTime(DEADLINE), () => {
			Seller.publish()
			transfer(balance(tokenId), tokenId).to(highestBidder)
			transfer(balance()).to(Seller)
			Auction.outcome(state.pad('accepted'), auctionInfo.title, lastPrice, Seller, highestBidder, tokenId)
			return false
		})
	transfer(balance(tokenId), tokenId).to(highestBidder)
	transfer(balance()).to(Seller)
	commit()
	exit()
})
