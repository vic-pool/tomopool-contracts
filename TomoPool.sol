pragma solidity ^0.5.0;

import "./Owner.sol";
import "./SafeMath.sol";

interface ICandidateManager {
    function teamAddress() external view returns (address payable);
}

contract CandidateManager is Ownable, ICandidateManager {
    using SafeMath for uint256;
    uint256 constant public BLOCK_PER_EPOCH = 900;

    constructor () public {
    }

    // only accept max node capacity => high reward for user
    uint256 public maxCapacity;

    // hardware fee  and other fee will transfer to team address
    address payable public team;

    address[] public candidates;

    struct CandidateState {
        uint256 capacity;
        bool isCandidate;
    }

    mapping(address => CandidateState) CandidatesState;

    event NewCandidate(address _candidate, string _name, address _coinbase);

    function setMaxCapacity(uint256 _maxCapacity) public onlyOwner {
        maxCapacity = _maxCapacity;
    }

    function newCandidate(string memory  _candidateName, address _coinbase) public onlyOwner {
        CandidateContract _candidate = new CandidateContract(_candidateName, _coinbase, address(this));
        CandidatesState[address(_candidate)] = CandidateState({
            capacity: 0,
            isCandidate: true
            });
        candidates.push(address(_candidate));
        emit NewCandidate(address(_candidate), _candidateName, _coinbase);
    }

    function changeTeamAddress(address payable _team) public onlyOwner {
        team = _team;
    }

    function getCandidates() public view returns (address[] memory) {
        return candidates;
    }

    function teamAddress() external view returns (address payable) {
        return team;
    }
    function currentEpoch() public view returns (uint256) {
        return block.number.sub(block.number.mod(BLOCK_PER_EPOCH)).div(BLOCK_PER_EPOCH);
    }
}

contract CandidateContract {
    using SafeMath for uint256;
    address public cm;
    string public CandidateName;
    address public coinbaseAddr;

    uint256 constant public BLOCK_PER_EPOCH = 900;
    uint256 constant public PENDING_STATUS = 1;
    uint256 constant public PROPOSED_STATUS = 10;
    uint256 constant public RESIGNED_STATUS = 100;
    uint256 public candidateStatus;
    address payable public referralAddress;

    uint256 public stakerWithdrawDelay = 96 * BLOCK_PER_EPOCH; //96 epochs = 2 days
    uint256 public candidateWithdrawDelay = 1440 * BLOCK_PER_EPOCH;//1440 epochs = 30 days
    uint256 public lastEpochRewardFilled; //the epoch at which rewards is filled/cached in EpochsReward
    uint256 public TotalRewardWithdrawn = 0;
    uint256 public TotalRewardEpochFilled = 0;
    // will take 10 -> 20% of the reward, depending on the tomo price to compensate on hardware
    uint256 public hardwareFeePercentage = 15;
    //used for recording the index of the withdraw index in validator contract, the index is increased if a unstake request is made
    uint256 public withdrawIndex = 1;
    uint256 public referralPercentage = 0;
    //lastEpochCapUnder60k = 0 means either the node is not in proposed, or the node's cap is not under 60k
    uint256 public lastEpochCapUnder60k = 0;
    uint256 public NUM_EPOCH_UNDER60k_TO_RESIGN = 48 * 10; //10 days

    //this is used for storing the state and history of unvotes
    struct WithdrawState {
        bool isWithdrawnStakeLocked;
        bool isWithdrawnCandidateLocked;
        mapping(uint256 => uint256) caps;
        uint256[] blockNumbers;
    }
    //map from block number to index
    mapping(uint256 => uint256) public indexes;//this corresponds the index parameter in tomovalidator withdraw function

    //history of unvote is saved per epoch
    mapping(address => WithdrawState) withdrawsState;

    mapping(uint256 => uint256) paymentHardwareHistory;
    mapping(uint256 => uint256) paymentReferralHistory;

    address payable constant public validator = 0x0000000000000000000000000000000000000088;

    // store reward every epoch: epoch 1 => [ stakerA => {capacity: 100, reward: 0.1 } ]
    mapping(uint256 => mapping(address => uint256)) public StakersReward;
    mapping(address => uint256) public StakerRewardWithdrawState;
    mapping(address => uint256) public StakersTotalReward;

    // the data that store snapshots of all changed stakers capacity, based on epochs, the capacity changes if any staker stake or unstake the votes
    mapping(uint256 => mapping(address => uint256)) public StakersCapacity;
    //mapping from address to list of epochs at which caps are changed
    mapping(address => uint256[]) public EpochsAtWhichCapChange;
    uint256 public CapBeforeResign = 0;
    bool public isStakeLockWithdrawn = false;
    bool public isCandidateLockWithdraw = false;
    uint256 public RemainingStakeAfterResign = 0;

    // current capacity of node
    uint256 public capacity;
    mapping(uint256 => uint256) public capacityHistory;
    uint256[] public capacityChanges;

    address [] public ListStaker;
    struct EpochReward {
        bool IsRewardPaid;
        uint256 rewards;
        uint256 actualRewards; //rewards after paying hardware fee
    }
    // check is ready calculate/paid reward
    mapping(uint256 => EpochReward) public EpochsReward;

    struct VoteResult {
        string description;
        mapping(address => bool) voteResults;
        uint256 supportCap;
        uint256 epochStart;
    }
    //mapping from the voting decision code to the result
    VoteResult public governance;

    event UnStake(address _staker, uint256 _amount);
    event WithdrawReward(address _staker, uint256 _reward);
    event Stake(address _staker, uint256 _amount);
    event SaveCapacityByEpoch(uint256 _epoch, uint256 _totalStaker, uint256 _capacity);
    event PaymentHardware(uint256 _epoch, uint256 _hardwareFeePercentage, uint256 _amount);
    event PaymentRef(uint256 _epoch, uint256 _refPercentage, uint256 _amount);
    event Withdraw(address _owner, uint256 _blockNumber, uint256 _cap);
    event CommunityVote(address _staker, uint256 _code, string _des, uint256 _cap, bool _support);
    event Resign(address _candidate);
    event Propose(address _candidate);
    event WithdrawAfterResign(address _staker, bool _isStakeLocked, uint256 _withdrawalCap);
    event TransferStake(address _from, address _to, uint256 _amount);

    constructor (string memory _candidateName, address _coinbase, address _cm) public {
        CandidateName = _candidateName;
        cm = _cm;
        coinbaseAddr = _coinbase;
        candidateStatus = PENDING_STATUS;
        lastEpochRewardFilled = 0;
        governance.epochStart = currentEpoch();
        governance.description = "Voting for resigning";
    }

    function setWithdrawDelay(uint256 _stake, uint256 _candidate) external onlyTeam {
        candidateWithdrawDelay = _candidate;
        stakerWithdrawDelay = _stake;
    }

    function currentEpoch() public view returns (uint256) {
        return block.number.sub(block.number.mod(BLOCK_PER_EPOCH)).div(BLOCK_PER_EPOCH);
    }

    //setHardwareFeePercentage as percentage of the reward
    function setHardwareFeePercentage(uint256 _hardwareFee) public onlyTeam {
        require(_hardwareFee >= 10 && _hardwareFee <= 20); //max 0.5$ per epoch
        hardwareFeePercentage = _hardwareFee;
    }

    function getHardwareFeePercentage() public view returns (uint256) {
        return hardwareFeePercentage;
    }

    function getHardwareFee(uint256 _reward) public view returns (uint256) {
        return getHardwareFeePercentage().mul(_reward).div(100);
    }

    function getRefBonus(uint256 _reward) public view returns (uint256) {
        return getRefBonusPercentage().mul(_reward).div(100);
    }

    function teamAddress() public view returns (address payable) {
        return ICandidateManager(cm).teamAddress();
    }

    modifier onlyTeam() {
        require(teamAddress() == msg.sender);
        _;
    }

    function stake() public payable {
        //The first stake
        if (getCurrentStakerCap(msg.sender) == 0) ListStaker.push(msg.sender);
        uint256 _ce = currentEpoch();
        require(candidateStatus < RESIGNED_STATUS);
        //change cap of staker coresponding to epoch
        StakersCapacity[_ce][msg.sender] = getCurrentStakerCap(msg.sender).add(msg.value);
        //mark the last epoch at which cap of the staker is changed
        if (EpochsAtWhichCapChange[msg.sender].length > 0) {
            if (EpochsAtWhichCapChange[msg.sender][EpochsAtWhichCapChange[msg.sender].length - 1] != _ce) {
                EpochsAtWhichCapChange[msg.sender].push(_ce);
            }
        } else {
            EpochsAtWhichCapChange[msg.sender].push(_ce);
        }
        //change cap of the pool and save it
        capacity = capacity.add(msg.value);
        saveCapacityHistory();
        if (candidateStatus == PROPOSED_STATUS) {
            (bool success,) = validator.call.value(msg.value)(abi.encodeWithSignature("vote(address)", coinbaseAddr));
            require(success, "Vote fail");
            if (governance.voteResults[msg.sender]) {
                governance.supportCap = governance.supportCap.add(msg.value);
                emit CommunityVote(msg.sender, 0, governance.description, msg.value, true);
            }
        }
        emit Stake(msg.sender, msg.value);
    }

    function transferStake(address to, uint256 _amount) external onlyStaker {
        require(_amount > 0);
        require(candidateStatus < RESIGNED_STATUS);
        uint256 currentSenderCap = getCurrentStakerCap(msg.sender);
        require(currentSenderCap >= _amount, "transfered amount is higher than the current cap");
        uint256 _ce = currentEpoch();
        //decrease stake of sender
        StakersCapacity[_ce][msg.sender] = currentSenderCap.sub(_amount);
        //log the cap change
        if (EpochsAtWhichCapChange[msg.sender][EpochsAtWhichCapChange[msg.sender].length - 1] != _ce) {
            EpochsAtWhichCapChange[msg.sender].push(_ce);
        }

        //remove sender from list of staker if cap becomes 0
        if (getCurrentStakerCap(msg.sender) == 0) {
            for (uint256 i = 0; i < ListStaker.length; i++) {
                if (ListStaker[i] == msg.sender) {
                    ListStaker[i] = ListStaker[ListStaker.length - 1];
                    ListStaker.pop();
                    break;
                }
            }
        }

        //add "to" to the staker list if the current stake is 0
        uint256 currentReceiverCap = getCurrentStakerCap(to);
        if (currentReceiverCap == 0) ListStaker.push(to);
        //change "to" cap
        StakersCapacity[_ce][to] = currentReceiverCap.add(_amount);
        //mark the last epoch at which cap of the staker is changed
        if (EpochsAtWhichCapChange[to].length > 0) {
            if (EpochsAtWhichCapChange[to][EpochsAtWhichCapChange[to].length - 1] != _ce) {
                EpochsAtWhichCapChange[to].push(_ce);
            }
        } else {
            EpochsAtWhichCapChange[to].push(_ce);
        }

        emit TransferStake(msg.sender, to, _amount);
    }

    function unstake(uint256 _amount) public {
        require(getCurrentStakerCap(msg.sender) >= _amount);
        uint256 _ce = currentEpoch();
        if (candidateStatus == PENDING_STATUS) {
            //nodes are not applied yet, just simply return funds to the staker
            StakersCapacity[_ce][msg.sender] = getCurrentStakerCap(msg.sender).sub(_amount);
            capacity = capacity.sub(_amount);
            EpochsAtWhichCapChange[msg.sender].push(_ce);
            saveCapacityHistory();
            msg.sender.transfer(_amount);
            emit UnStake(msg.sender, _amount);
        } else {
            require(candidateStatus < RESIGNED_STATUS, "staker cannot unstake once the node is resigned");
            require(capacity.sub(_amount) >= 50000 ether, "unstake amount too large, need to resign the node before unstaking more");
            StakersCapacity[_ce][msg.sender] = getCurrentStakerCap(msg.sender).sub(_amount);
            capacity = capacity.sub(_amount);
            EpochsAtWhichCapChange[msg.sender].push(_ce);
            saveCapacityHistory();

            //save withdrawsState
            // refund after delay X blocks
            uint256 withdrawBlockNumber = stakerWithdrawDelay.add(block.number);
            //only one stake can be done in a block to avoid withdraw collision
            require(indexes[withdrawBlockNumber] == 0, "another voter already unvote in this block");

            withdrawsState[msg.sender].caps[withdrawBlockNumber] = withdrawsState[msg.sender].caps[withdrawBlockNumber].add(_amount);
            withdrawsState[msg.sender].blockNumbers.push(withdrawBlockNumber);
            indexes[withdrawBlockNumber] = withdrawIndex;
            withdrawIndex = withdrawIndex.add(1);

            (bool success,) = validator.call(abi.encodeWithSignature("unvote(address,uint256)", coinbaseAddr, _amount));
            require(success, "unvote failed");
            emit UnStake(msg.sender, _amount);

            //reduce the support cap if the staker is supporting resigning decision
            if (governance.voteResults[msg.sender]) {
                governance.supportCap = governance.supportCap.sub(_amount);
                emit CommunityVote(msg.sender, 0, governance.description, _amount, false);
            }
        }

        if (getCurrentStakerCap(msg.sender) == 0) {
            for (uint256 i = 0; i < ListStaker.length; i++) {
                if (ListStaker[i] == msg.sender) {
                    ListStaker[i] = ListStaker[ListStaker.length - 1];
                    ListStaker.pop();
                    break;
                }
            }
        }
    }

    modifier onlyStaker {
        require(getCurrentStakerCap(msg.sender) > 0);
        _;
    }

    function withdrawStake(uint256 _blockNumber) public {
        require(_blockNumber > 0);
        if (candidateStatus >= PROPOSED_STATUS) {
            require(block.number >= _blockNumber);
            require(withdrawsState[msg.sender].caps[_blockNumber] > 0);
            require(indexes[_blockNumber] > 0);

            uint256 cap = withdrawsState[msg.sender].caps[_blockNumber];
            uint256 balanceBefore = address(this).balance;
            (bool success,) = validator.call(abi.encodeWithSignature("withdraw(uint256,uint256)", _blockNumber, indexes[_blockNumber].sub(1)));
            require(success);
            uint256 balanceAfter = address(this).balance;
            require(balanceAfter.sub(balanceBefore) >= cap);
            delete withdrawsState[msg.sender].caps[_blockNumber];
            delete indexes[_blockNumber];
            msg.sender.transfer(cap);
            emit Withdraw(msg.sender, _blockNumber, cap);
        } else {
            uint256 _ce = currentEpoch();
            uint256 _amount = getCurrentStakerCap(msg.sender);
            StakersCapacity[_ce][msg.sender] = getCurrentStakerCap(msg.sender).sub(_amount);
            capacity = capacity.sub(_amount);
            EpochsAtWhichCapChange[msg.sender].push(_ce);
            saveCapacityHistory();

            for (uint256 i = 0; i < ListStaker.length; i++) {
                if (ListStaker[i] == msg.sender) {
                    ListStaker[i] = ListStaker[ListStaker.length - 1];
                    ListStaker.pop();
                    break;
                }
            }
            msg.sender.transfer(_amount);
            emit Withdraw(msg.sender, _blockNumber, _amount);
        }
    }

    function propose() public onlyStaker {
        require(address(this).balance >= 50000 ether);
        require(candidateStatus < PROPOSED_STATUS);
        (bool success,) = validator.call.value(address(this).balance)(abi.encodeWithSignature("propose(address)", coinbaseAddr));
        require(success, "propose failed");
        candidateStatus = PROPOSED_STATUS;
        governance.epochStart = currentEpoch();
        emit Propose(address(this));
    }

    function withdrawAfterResign(address payable _staker, bool checkStakeLock) public {
        require(isWithdrawAfterResignAvailable(_staker, checkStakeLock), "Withdrawal is not available or Staker already withdrawed the stake");
        uint256 _stakerCap = getCurrentStakerCap(_staker);
        uint256 _currentCap = _stakerCap;
        if (!withdrawsState[_staker].isWithdrawnStakeLocked && !withdrawsState[_staker].isWithdrawnCandidateLocked) {
            if (checkStakeLock) {
                withdrawsState[_staker].isWithdrawnStakeLocked = true;
                _stakerCap = CapBeforeResign.sub(50000 * 10**18).mul(_stakerCap).div(CapBeforeResign);
            } else {
                _stakerCap = _stakerCap.mul(50000 * 10**18).div(CapBeforeResign);
                withdrawsState[_staker].isWithdrawnCandidateLocked = true;
            }
        } else {
            withdrawsState[_staker] .isWithdrawnStakeLocked = true;
            withdrawsState[_staker].isWithdrawnCandidateLocked = true;
        }
        uint256 _ce = currentEpoch();
        StakersCapacity[_ce][_staker] = _currentCap.sub(_stakerCap);
        EpochsAtWhichCapChange[_staker].push(_ce);
        uint8 idx = checkStakeLock? 0: 1;
        uint256 _blockNumber = withdrawsState[address(this)].blockNumbers[idx];
        if ((checkStakeLock && !isStakeLockWithdrawn) || (!checkStakeLock && !isCandidateLockWithdraw)) {
            //withdraw
            uint256 balBefore = address(this).balance;
            (bool success,) = validator.call(abi.encodeWithSignature("withdraw(uint256,uint256)", _blockNumber, indexes[_blockNumber].sub(1)));
            require(success, "withdraw failed");
            if (checkStakeLock)
                isStakeLockWithdrawn = true;
            else
                isCandidateLockWithdraw = true;
            RemainingStakeAfterResign = RemainingStakeAfterResign.add(address(this).balance.sub(balBefore));
        }
        RemainingStakeAfterResign = RemainingStakeAfterResign.sub(_stakerCap);
        _staker.transfer(_stakerCap);
        emit WithdrawAfterResign(_staker, checkStakeLock, _stakerCap);
    }

    function isWithdrawAfterResignAvailable(address _staker, bool checkStakeLock) public view returns (bool) {
        if (isAlreadyWithdrawAfterResign(_staker, checkStakeLock)) {
            return false;
        }
        if (candidateStatus >= RESIGNED_STATUS) {
            uint8 idx = checkStakeLock? 0: 1;
            return block.number >= withdrawsState[address(this)].blockNumbers[idx];
        }
        return false;
    }

    function isAlreadyWithdrawAfterResign(address _staker, bool checkStakeLock) public view returns (bool) {
        return (checkStakeLock && withdrawsState[_staker].isWithdrawnStakeLocked) || (!checkStakeLock && withdrawsState[_staker].isWithdrawnCandidateLocked);
    }

    function resign() public onlyStaker {
        require(candidateStatus == PROPOSED_STATUS);
        //the resigning decision has been supported by majority of stake
        require(governance.supportCap >= capacity.mul(66).div(100));
        resignInternal();
    }

    function resignInternal() private {
        CapBeforeResign = capacity;
        bool success;
        uint256 _unvoteAmount = capacity.sub(50000 * 10**18);

        (success,) = validator.call(abi.encodeWithSignature("unvote(address,uint256)", coinbaseAddr, _unvoteAmount));
        require(success, "resign failed");

        uint256 withdrawBlockNumber = stakerWithdrawDelay.add(block.number);
        withdrawsState[address(this)].caps[withdrawBlockNumber] = withdrawsState[address(this)].caps[withdrawBlockNumber].add(_unvoteAmount);
        withdrawsState[address(this)].blockNumbers.push(withdrawBlockNumber);
        indexes[withdrawBlockNumber] = withdrawIndex;
        withdrawIndex = withdrawIndex.add(1);

        //resign
        (success,) = validator.call(abi.encodeWithSignature("resign(address)", coinbaseAddr));
        require(success, "resign failed");
        candidateStatus = RESIGNED_STATUS;

        // refunding after resigning X blocks
        withdrawBlockNumber = candidateWithdrawDelay.add(block.number);
        withdrawsState[address(this)].caps[withdrawBlockNumber] = withdrawsState[address(this)].caps[withdrawBlockNumber].add(capacity.sub(_unvoteAmount));
        withdrawsState[address(this)].blockNumbers.push(withdrawBlockNumber);
        indexes[withdrawBlockNumber] = withdrawIndex;
        withdrawIndex = withdrawIndex.add(1);

        emit Resign(address(this));

        //do we need to reduce capacity here?  or do we need to store unvote history to withdraw later?
        capacity = 0;
        saveCapacityHistory();
    }

    function canResign() public view returns(bool){
        return governance.supportCap >= capacity.mul(66).div(100);
    }

    function resignIfUnder60k() public onlyStaker {
        uint256 _currentEpoch = currentEpoch();
        require(capacity < 60000 * 10**18 && lastEpochCapUnder60k > 0 && _currentEpoch >= NUM_EPOCH_UNDER60k_TO_RESIGN.add(lastEpochCapUnder60k), "Forced resign is only allowed if the node has 60k for 10 consecutive days");
        resignInternal();
    }

    // This function can be called at any time in order to save the capacity of the pool stored per epoch
    function saveCapacityHistory() public {
        uint256 _currentEpoch = currentEpoch();
        capacityHistory[_currentEpoch] = capacity;
        if (capacityChanges.length > 0) {
            if (capacityChanges[capacityChanges.length - 1] < _currentEpoch) {
                capacityChanges.push(_currentEpoch);
            }
        } else {
            capacityChanges.push(_currentEpoch);
        }
        if (capacity <= 60000 ether && candidateStatus >= PROPOSED_STATUS) {
            lastEpochCapUnder60k = _currentEpoch;
        } else {
            lastEpochCapUnder60k = 0;
        }
        emit SaveCapacityByEpoch(_currentEpoch, ListStaker.length, capacity);
    }

    function getCurrentStakerCap(address staker) public view returns (uint256) {
        return getStakerCapacityByEpoch(currentEpoch(), staker);
    }

    //this function is used for equally dividing rewards to missing epochs in which distributeRewards function is not called on time
    function fillRewardsPerEpoch() public {
        uint256 _currentEpoch = currentEpoch();
        if (lastEpochRewardFilled == 0) {
            lastEpochRewardFilled = _currentEpoch.sub(3);
        }
        uint256 _epochToFill = lastEpochRewardFilled.add(1);
        if (_currentEpoch.sub(1) > _epochToFill) {
            //fill rewards for epochs
            uint256 numEpochsWaitingToFill = _currentEpoch.sub(_epochToFill).sub(1);
            uint256 endEpoch = _epochToFill.add(numEpochsWaitingToFill).sub(1);

            uint256 notFilledRewards = address(this).balance.add(TotalRewardWithdrawn).sub(TotalRewardEpochFilled).sub(RemainingStakeAfterResign);
            uint256 rewardsPerEpoch = notFilledRewards.div(numEpochsWaitingToFill);
            uint256 remainingBalance = notFilledRewards;
            for (uint256 i = _epochToFill; i < endEpoch; i++) {
                EpochsReward[i].rewards = rewardsPerEpoch;
                remainingBalance = remainingBalance.sub(rewardsPerEpoch);
                payHardwareFee(i);
            }
            EpochsReward[endEpoch].rewards = remainingBalance;
            lastEpochRewardFilled = endEpoch;
            payHardwareFee(endEpoch);
            TotalRewardEpochFilled = TotalRewardEpochFilled.add(notFilledRewards);
        }
    }

    function communityVote(bool support) public onlyStaker {
        require(candidateStatus == PROPOSED_STATUS);
        if (support != governance.voteResults[msg.sender]) {
            governance.voteResults[msg.sender] = support;
            if (support) {
                //from not support to support ==> increase support cap
                governance.supportCap = governance.supportCap.add(getCurrentStakerCap(msg.sender));
            } else {
                governance.supportCap = governance.supportCap.sub(getCurrentStakerCap(msg.sender));
            }
            emit CommunityVote(msg.sender, 0, governance.description, getCurrentStakerCap(msg.sender), support);
        }
    }

    function isVoted(address _staker) public view returns (bool) {
        if (governance.voteResults[_staker]) {
            return governance.voteResults[_staker];
        }
        return false;
    }

    function payHardwareFee(uint256 epochToPay) private returns (uint256, uint256) {
        uint256 _reward = EpochsReward[epochToPay].rewards;
        uint256 _feeAndReferral = 0;
        if ((paymentHardwareHistory[epochToPay].add(paymentReferralHistory[epochToPay])) == 0 && _reward > 0) {
            //hardware reward fee has not been paid
            uint256 _fee = getHardwareFee(_reward);
            address payable team = teamAddress();

            //send even _fee might be zero
            team.transfer(_fee);
            paymentHardwareHistory[epochToPay] = _fee;
            emit PaymentHardware(epochToPay, getHardwareFeePercentage(), _fee);

            uint256 _refBonus = getRefBonus(_reward);
            referralAddress.transfer(_refBonus);
            paymentReferralHistory[epochToPay] = _refBonus;
            emit PaymentRef(epochToPay, getRefBonusPercentage(), _refBonus);

            EpochsReward[epochToPay].actualRewards = _reward.sub(_fee).sub(_refBonus);
            TotalRewardWithdrawn = TotalRewardWithdrawn.add(_fee).add(_refBonus);
            _feeAndReferral = _fee.add(_refBonus);
        }
        return (_feeAndReferral, EpochsReward[epochToPay].actualRewards);
    }

    function withdrawAllRewardsOfStaker(address payable _staker) public {
        require(EpochsAtWhichCapChange[_staker].length > 0);
        fillRewardsPerEpoch();
        uint256 lastWithdrawEpoch = getLastWithdrawEpochOfStaker(_staker);
        uint256 _ce = currentEpoch();
        uint256 _rewardAmount = 0;
        //withdraw is only available for epoch before the epoch before the current epoch
        for (uint256 i = lastWithdrawEpoch.add(1); i <= _ce.sub(2); i++) {
            (uint256 _stakerReward,) = computeStakerRewardByEpoch(_staker, i);
            StakersReward[i][_staker] = _stakerReward;
            _rewardAmount = _rewardAmount.add(_stakerReward);
        }
        if (_rewardAmount > 0) {
            _staker.transfer(_rewardAmount);
            StakersTotalReward[_staker] = StakersTotalReward[_staker].add(_rewardAmount);
            emit WithdrawReward(_staker, _rewardAmount);
            TotalRewardWithdrawn = TotalRewardWithdrawn.add(_rewardAmount);
        }
        StakerRewardWithdrawState[_staker] = _ce.sub(2);
    }

    function computeTotalStakerReward(address _staker) public view returns (uint256) {
        uint256 lastWithdrawEpoch = getLastWithdrawEpochOfStaker(_staker);
        uint256 _ce = currentEpoch();
        uint256 _rewardAmount = 0;
        for (uint256 i = lastWithdrawEpoch.add(1); i <= _ce.sub(2); i++) {
            (uint256 _stakerReward,) = computeStakerRewardByEpoch(_staker, i);
            _rewardAmount = _rewardAmount.add(_stakerReward);
        }
        return _rewardAmount;
    }

    function computeStakerRewardByEpoch(address _staker, uint256 _epoch) public view returns (uint256, uint256) {
        uint256 _stakerCapacity = getStakerCapacityByEpoch(_epoch, _staker);
        uint256 _candidateCapacity = getCapacityByEpoch(_epoch);
        uint256 actualRewards = EpochsReward[_epoch].actualRewards;
        if (actualRewards == 0) {
            //estimate epoch reward
            uint256 _currentEpoch = currentEpoch();
            uint256 _lastEpochRewardFilled = lastEpochRewardFilled;
            if (_lastEpochRewardFilled == 0) {
                _lastEpochRewardFilled = _currentEpoch.sub(3);
            }
            uint256 _epochToFill = _lastEpochRewardFilled.add(1);
            if (_currentEpoch.sub(1) > _epochToFill) {
                //fill rewards for epochs
                uint256 numEpochsWaitingToFill = _currentEpoch.sub(_epochToFill).sub(1);

                uint256 notFilledRewards = address(this).balance.add(TotalRewardWithdrawn).sub(TotalRewardEpochFilled).sub(RemainingStakeAfterResign);
                uint256 _reward = notFilledRewards.div(numEpochsWaitingToFill);
                actualRewards = _reward.sub(getHardwareFee(_reward)).sub(getRefBonus(_reward));
            }
        }
        return (_stakerCapacity.mul(actualRewards).div(_candidateCapacity), _stakerCapacity);
    }

    function getLastWithdrawEpochOfStaker(address _staker) public view returns (uint256){
        uint256 lastWithdrawEpoch = StakerRewardWithdrawState[_staker];
        uint256 firstEpoch = EpochsAtWhichCapChange[_staker][0];
        lastWithdrawEpoch = lastWithdrawEpoch > firstEpoch ? lastWithdrawEpoch : firstEpoch;
        return lastWithdrawEpoch;
    }

    function getStakerCapacityByEpoch(uint256 epoch, address addr) public view returns (uint256) {
        //find best match epoch
        if (EpochsAtWhichCapChange[addr].length == 0) return 0;
        for (uint256 i = EpochsAtWhichCapChange[addr].length - 1; i >= 0; i--) {
            if (epoch >= EpochsAtWhichCapChange[addr][i]) {
                return StakersCapacity[EpochsAtWhichCapChange[addr][i]][addr];
            }
            if (i == 0) break;
        }
        return 0;
    }

    function getCapacityByEpoch(uint256 epoch) public view returns (uint256) {
        for (uint256 i = capacityChanges.length - 1; i >= 0; i--) {
            if (epoch >= capacityChanges[i]) {
                return capacityHistory[capacityChanges[i]];
            }
            if (i == 0) break;
        }
        return 0;
    }

    function getStakerCurrentReward(address _staker) public view returns (uint256) {
        return getRewardByEpoch(_staker, currentEpoch());
    }
    function getStakerTotalReward(address _staker) public view returns (uint256) {
        return StakersTotalReward[_staker];
    }
    function getRewardByEpoch(address _staker, uint256 _epoch) public view returns (uint256) {
        if (StakersReward[_epoch][_staker] > 0) {
            return StakersReward[_epoch][_staker];
        }
        (uint256 _r,) = computeStakerRewardByEpoch(_staker, _epoch);
        return _r;
    }

    //this function will only rreturns block numbers that stakes are not withdrawn yet
    function getWithdrawBlockNumbers(address _staker) public view returns(uint256[] memory) {
        return withdrawsState[_staker].blockNumbers;
    }

    function getWithdrawCap(address _staker, uint256 _blockNumber) public view returns(uint256) {
        return withdrawsState[_staker].caps[_blockNumber];
    }

    function isWithdrawn(uint256 _blockNumber) public view returns (bool) {
        return indexes[_blockNumber] == 0;
    }

    function () external payable {
        if (msg.sender != validator) stake();
    }

    function getListStaker() public view returns (address[] memory) {
        return ListStaker;
    }

    function setReferralAddress(address payable _r) external onlyTeam () {
        referralAddress = _r;
    }

    function getReferralAddress() public view returns (address payable) {
        return referralAddress;
    }

    function setRefBonusPercentage(uint256 _bonus) public onlyTeam {
        require(_bonus <= 20);
        referralPercentage = _bonus;
    }

    function getRefBonusPercentage() public view returns (uint256) {
        return referralPercentage;
    }
}
