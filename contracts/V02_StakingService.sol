// SPDX-License-Identifier: MIT
pragma solidity >=0.7.0 <0.8.0;

import "./NmxSupplier.sol";
import "./PausableByOwner.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "abdk-libraries-solidity/ABDKMath64x64.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2ERC20.sol";

contract StakingService is PausableByOwner {
    /**
     * @param historicalRewardRate how many NMX rewards for one NMXLP
     * @param totalStaked how many NMXLP are staked in total
     */
    struct State {
        uint256 totalStaked;
        uint256 historicalRewardRate;
    }
    /**
     * @param amount how much NMXLP staked
     * @param initialRewardRate rice at which the reward was last paid
     * @param reward total nmx amount user got as a reward
     */
    struct Staker {
        uint256 amount;
        uint256 initialRewardRate;
        uint256 reward;
        uint256 unclaimedReward;
    }

    bytes32 public DOMAIN_SEPARATOR;
    string private constant CLAIM_TYPE = "Claim(adress owner,adress spender,uint amount,address wallet,uint nonce,uint deadline)";
    bytes32 public CLAIM_TYPEHASH = keccak256(abi.encodePacked(CLAIM_TYPE));

    mapping(address => uint256) public nonces;

    /**
     * @dev Nmx contract
     */
    address nmx;
    /**
     * @dev ERC20 TODO
     */
    address stakingToken;
    /**
     * @dev to got minted NMX
     */
    address nmxSupplier;
    /**
     * @dev internal service state
     */
    State state;

    /**
     * @dev trusted contract for nmx reinvesting
     */
    address public reinvestContract;
    /**
     * @dev mapping a staker's address to his state
     */
    mapping(address => Staker) public stakers;

    /**
     * @dev event when someone is staked NMXLP
     */
    event Staked(address indexed owner, uint256 amount);
    /**
     * @dev event when someone unstaked NMXLP
     */
    event Unstaked(address indexed owner, uint256 amount);
    /**
     * @dev event when someone is awarded NMX
     */
    event Rewarded(address indexed owner, uint256 amount);

    /**
     * @dev event when someone is awarded NMX
     */
    event ClaimedForReinvest(address indexed owner, uint256 amount);

    constructor(
        address _nmx,
        address _stakingToken,
        address _nmxSupplier
    ) {
        nmx = _nmx;
        stakingToken = _stakingToken;
        nmxSupplier = _nmxSupplier;

        uint256 chainId;
        assembly {
            chainId := chainid()
        }

        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256(bytes("StakingService")),
                keccak256(bytes("1")),
                chainId,
                address(this)
            )
        );

    }

    function setReinvestContract(address _reinvestContract) external onlyOwner {
        reinvestContract = _reinvestContract;
    }

    /**
     * @dev accepts NMXLP staked by the user, also rewards for the previously staked amount at the current rate
     * emit Staked and Rewarded events
     *
     * amount - new part of staked NMXLP
     */
    function stake(uint256 amount) public whenNotPaused {
        _stakeFrom(msg.sender, amount);
    }

    function stakeWithPermit(
        uint256 amount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external whenNotPaused {
        IUniswapV2ERC20(stakingToken).permit(
            msg.sender,
            address(this),
            amount,
            deadline,
            v,
            r,
            s
        );
        stake(amount);
    }

    function stakeFrom(
        address owner,
        uint256 amount
    ) external whenNotPaused {
        _stakeFrom(owner, amount);
    }

    function _stakeFrom(address owner, uint256 amount) private {
        bool transferred =
        IERC20(stakingToken).transferFrom(
            msg.sender,
            address(this),
            amount
        );
        require(transferred, "NMXSTKSRV: LP_FAILED_TRANSFER");
        updateHistoricalRewardRate();

        Staker storage staker = stakers[owner];
        _updateReward(staker);

        emit Staked(owner, amount);
        state.totalStaked += amount;
        staker.amount += amount;
    }

    /**
     * @dev accepts NMXLP unstaked by the user, also rewards for the previously staked amount at the current rate
     * emit Unstaked and Rewarded events
     *
     * amount - new part of staked NMXLP
     */
    function unstake(uint256 amount) external {
        Staker storage staker = stakers[msg.sender];
        require(staker.amount >= amount, "NMXSTKSRV: NOT_ENOUGH_STAKED");
        bool transferred = IERC20(stakingToken).transfer(msg.sender, amount);
        require(transferred, "NMXSTKSRV: LP_FAILED_TRANSFER");
        updateHistoricalRewardRate();

        _updateReward(staker);

        emit Unstaked(msg.sender, amount);
        state.totalStaked -= amount;
        staker.amount -= amount;
    }

    /**
     * @dev reward transfe
     * emit Rewarded event
     *
     * amount - new part of staked NMXLP
     */
    function claimReward() external {
        updateHistoricalRewardRate();
        address owner = msg.sender;
        Staker storage staker = stakers[owner];
        _updateReward(staker);
        emit Rewarded(owner, staker.unclaimedReward);
        bool transferred = IERC20(nmx).transfer(owner, staker.unclaimedReward);
        require(transferred, "NMXSTKSRV: NMX_FAILED_TRANSFER");
        staker.unclaimedReward = 0;
    }

    function claimForReinvest(
        address owner,
        address to,
        uint256 nmxAmount,
        uint256 signedAmount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s) external {
        require(nmxAmount <= signedAmount);
        verifySignature(owner, msg.sender, signedAmount, deadline, v, r, s);

        if (nmxAmount == 0) {
            return;
        }

        updateHistoricalRewardRate();
        Staker storage staker = stakers[owner];
        _updateReward(staker);
        require(nmxAmount >= staker.unclaimedReward, "NMXSTKSRV: NOT_ENOUGH_BALANCE");
        bool transferred = IERC20(nmx).transfer(to, nmxAmount);
        require(transferred, "NMXSTKSRV: NMX_TRANSFER_FAIlED");
        staker.unclaimedReward -= nmxAmount;
        emit Rewarded(owner, nmxAmount);
    }

    function verifySignature(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s) private {
        require(deadline >= block.timestamp, "NMXSTKSRV: EXPIRED");
        bytes32 digest =
        keccak256(
            abi.encodePacked(
                "\x19\x01",
                DOMAIN_SEPARATOR,
                keccak256(
                    abi.encode(
                        CLAIM_TYPEHASH,
                        owner,
                        spender,
                        value,
                        nonces[owner]++,
                        deadline
                    )
                )
            )
        );
        address recoveredAddress = ecrecover(digest, v, r, s);
        require(
            recoveredAddress != address(0) && recoveredAddress == owner,
            "NMX: INVALID_SIGNATURE"
        );
    }

    /**
     * @dev updates state and returns unclaimed reward amount.
     */
    function getReward() external returns (uint256) {
        address owner = msg.sender;
        Staker storage staker = stakers[owner];
        _updateReward(staker);
        return staker.unclaimedReward;
    }

    /**
     * @dev TODO
     */
    function _updateReward(Staker storage staker) private {
        uint256 unrewarded =
            ((state.historicalRewardRate - staker.initialRewardRate) *
                staker.amount) / 10**18;
        staker.initialRewardRate = state.historicalRewardRate;
        staker.reward += unrewarded;
        staker.unclaimedReward += unrewarded;
    }

    /**
     * @dev update how many NMX rewards for one NMXLP are currently
     */
    function updateHistoricalRewardRate() public {
        if (paused()) {
            return;
        }
        uint256 currentNmxSupply = NmxSupplier(nmxSupplier).supplyNmx();
        if (state.totalStaked != 0 && currentNmxSupply != 0)
            state.historicalRewardRate +=
                (currentNmxSupply * 10**18) /
                state.totalStaked;
    }

    function totalStaked() external view returns (uint256) {
        return state.totalStaked;
    }

}
