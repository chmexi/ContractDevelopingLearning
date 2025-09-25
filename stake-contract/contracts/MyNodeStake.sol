// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

contract MyNodeStake is 
    Initializable,
    UUPSUpgradeable,
    PausableUpgradeable,
    AccessControlUpgradeable
{
    using SafeERC20 for IERC20;
    using Address for address;
    using Math for uint256;

    // ----------------------------INVARIANT----------------------------
    bytes32 public constant ADMIN_ROLE = keccak256("meta_admin");
    bytes32 public constant UPGRADE_ROLE = keccak256("meta_upgrade");

    uint256 public constant ETH_PID = 0;

    // ----------------------------DATA STRUCTURE----------------------------
    struct Pool {
        // 质押代币地址
        address stTokenAddress;        
        // 池权重
        uint256 poolWeight;
        // 上次结算奖励的区块号
        uint256 lastRewardBlock;
        // 每单位质押代币累计的MetaNode奖励
        uint256 accMetaNodePerST;
        // 当前池中总代笔数量
        uint256 stTokenAmount;
        // 最小质押数量
        uint256 minDepositAmount;
        // 解除质押后的锁仓区块数
        uint256 unstakeLockedBlocks;
    }

    struct UnstakeRequest {
        // 解除质押数量
        uint256 amount;
        // 解除锁仓，用户可以提取资金的区块号
        uint256 unlockBlocks;
    }

    struct User {
        // 用户质押代币总数
        uint256 stAmount;
        // 用户最终得到的MetaNode数目
        uint256 finishedMetaNode;
        // 当前可提取MetaNode数目
        uint256 pendingMetaNode;
        // 提取请求列表
        UnstakeRequest[] requests;
    }
    // ----------------------------STATE VARIABLE----------------------------
    // 质押合约开始区块号
    uint256 startBlock;
    // 质押合约结束区块号
    uint256 endBlock;
    // 每个区块奖励的代币数目
    uint256 MetaNodePerBlock;

    // 暂停提取质押的资产状态量
    bool public withdrawPaused;
    // 暂停领取奖励状态量
    bool public claimPaused;

    // 奖励代币
    IERC20 public MetaNode;

    // 池总体权重，所有池权重的和
    uint256 public totalPoolWeight;
    Pool[] public pool;

    // pool id => user address => user info
    mapping(uint256 => mapping(address => User)) public user;

    // ----------------------------EVENT----------------------------
    event SetMetaNode(IERC20 indexed MetaNode);

    event PauseWithdraw();
    event PauseClaim();
    event UnpauseWithdraw();
    event UnpauseClaim();

    event SetStartBlock(uint256 indexed startBlock);
    
    event SetEndBlock(uint256 indexed startBlock);

    event SetMetaNodePerBlock(uint256 indexed MetaNodePerBlock);

    event AddPool(address indexed stTokenAddress, uint256 indexed poolWeight, uint256 indexed lastRewardBlock, uint256 minDepositAmount, uint256 unstakeLockedBlocks);
    
    event UpdatePoolInfo(uint256 indexed poolId, uint256 indexed minDepositAmount, uint256 indexed unstakeLockedBlocks);

    event SetPoolWeight(uint256 indexed poolId, uint256 indexed poolWeight, uint256 indexed totalPoolWeight);
    
    // ----------------------------MODIFIER----------------------------
    modifier checkPid(uint256 _pid) {
        require(_pid < pool.length, "invalid pid");
        _;
    }

    modifier whenNotWithdrawPaused {
        require(!withdrawPaused, "withdraw is paused");
        _;
    }

    modifier whenNotClaimPaused {
        require(!claimPaused, "claim is paused");
        _;
    }

    function Initailize(
        IERC20 _MetaNode,
        uint256 _startBlock,
        uint256 _endBlock,
        uint256 _MetaNodePerBlock
    ) public initializer {
        require(_startBlock < _endBlock && _MetaNodePerBlock > 0, "Invalid Parameter");

        __AccessControl_init();
        __UUPSUpgradeable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(UPGRADE_ROLE, msg.sender);

        setMetaNode(_MetaNode);
    }

    function _authorizeUpgrade(address _newImplementation)
        internal 
        onlyRole(UPGRADE_ROLE)
        override
        {

        }

    // ----------------------------ADMIN FUNCTION----------------------------
    function setMetaNode(IERC20 _MetaNode) public onlyRole(ADMIN_ROLE) {
        MetaNode = _MetaNode;

        emit SetMetaNode(MetaNode);
    }

    function pauseWithdraw() public onlyRole(ADMIN_ROLE) {
        require(!withdrawPaused, "withdraw is already paused");

        withdrawPaused = true;
        emit PauseWithdraw();
    }

    function pauseClaim() public onlyRole(ADMIN_ROLE) {
        require(!claimPaused, "claim is already paused");

        claimPaused = true;
        emit PauseClaim();
    }

    function unpauseWithdraw() public onlyRole(ADMIN_ROLE) {
        require(withdrawPaused, "withdraw is already unpaused");

        withdrawPaused = false;
        emit UnpauseWithdraw();
    }

    function unpauseClaim() public onlyRole(ADMIN_ROLE) {
        require(!claimPaused, "claim is already unpaused");

        claimPaused = false;
        emit UnpauseClaim();
    }

    function setStartBlock(uint256 _startBlock) public onlyRole(ADMIN_ROLE) {
        require(_startBlock <= endBlock, "start block must be smaller than endBlock");
        startBlock = _startBlock;
        emit SetStartBlock(_startBlock);
    }

    function setEndBlock(uint256 _endBlock) public onlyRole(ADMIN_ROLE) {
        require(startBlock <= _endBlock, "endBlock must be bigger than startBlock");
        endBlock = _endBlock;
        emit SetEndBlock(_endBlock);
    }

    function setMetaNodePerBlock(uint256 _MetaNodePerBlock) public onlyRole(ADMIN_ROLE) {
        require(_MetaNodePerBlock > 0, "invalid parameter");

        MetaNodePerBlock = _MetaNodePerBlock;

        emit SetMetaNodePerBlock(_MetaNodePerBlock);
    }

    function addPool(address _stTokenAddress, uint256 _poolWeight, uint256 _minDepositAmount, uint256 _unstakeLockedBlocks, bool _withUpdate) public onlyRole(ADMIN_ROLE) {
        // 第一个池必须是eth池，所以地址为0x0
        if (pool.length > 0) {
            require(_stTokenAddress != address(0x0), "invalid parameter");
        } else {
            require(_stTokenAddress == address(0x0), "invalid parameter");
        }
        require(_minDepositAmount > 0, "invalid deposite amount");
        require(block.number < endBlock, "pool has already ended");

        if (_withUpdate) {
            massUpdatePools();
        }

        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalPoolWeight = totalPoolWeight + _poolWeight;

        pool.push(Pool({
            stTokenAddress: _stTokenAddress,
            poolWeight: _poolWeight,
            lastRewardBlock: lastRewardBlock,
            accMetaNodePerST: 0,
            stTokenAmount: 0,
            minDepositAmount: _minDepositAmount,
            unstakeLockedBlocks: _unstakeLockedBlocks
        }));

        emit AddPool(_stTokenAddress, _poolWeight, lastRewardBlock, _minDepositAmount, _unstakeLockedBlocks);
    }

    function updatePool(uint256 _pid, uint256 _minDepositAmount, uint256 _unstakeLockedBlocks) public onlyRole(ADMIN_ROLE) {
        pool[_pid].minDepositAmount = _minDepositAmount;
        pool[_pid].unstakeLockedBlocks = _unstakeLockedBlocks;

        emit UpdatePoolInfo(_pid, _minDepositAmount, _unstakeLockedBlocks);
    }

    function setPoolWeight(uint256 _pid, uint256 _poolWeight, bool _withUpdate) public onlyRole(ADMIN_ROLE) checkPid(_pid) {
        require(_poolWeight > 0, "invalid parameter");
        if (_withUpdate) {
            massUpdatePools();
        }

        totalPoolWeight = totalPoolWeight - pool[_pid].poolWeight + _poolWeight;
        pool[_pid].poolWeight = _poolWeight;

        emit SetPoolWeight(_pid, _poolWeight, totalPoolWeight);
    }


    // ----------------------------PUBLIC FUNCTION----------------------------
    function updatePool(uint256 _pid) public checkPid(_pid) {
        
    }

    function massUpdatePools() public {
        uint256 length = pool.length;
        for (uint256 pid = 0; pid < length; pid++) {
            updatePool(pid);
        }
    }


    function depositeETH() public whenNotPaused() payable {

    }

    function deposit(uint256 _pid, uint256 _amount) public {

    }

    function unstake(uint256 _pid, uint256 _amount) public {

    }

    function withdraw(uint256 _pid) public whenNotPaused() checkPid(_pid) {

    } 

    // 获取MetaNode奖励 
    function claim(uint256 _pid) public whenNotPaused() checkPid(_pid) {

    }


    // ----------------------------INTERNAL FUNCTION----------------------------

    
}