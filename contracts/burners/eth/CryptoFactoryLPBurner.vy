# @version 0.3.1
"""
@title Crypto Factory LP Burner
@notice Withdraws Crypto LP tokens
"""


interface ERC20:
    def transferFrom(_from: address, _to: address, _value: uint256) -> bool: nonpayable
    def balanceOf(_owner: address) -> uint256: view
    def decimals() -> uint256: view

interface CurveToken:
    def minter() -> address: view

interface CryptoSwap:
    def remove_liquidity(_amount: uint256, min_amounts: uint256[2],
                         use_eth: bool = False, receiver: address = msg.sender): nonpayable
    def remove_liquidity_one_coin(token_amount: uint256, i: uint256, min_amount: uint256,
                                  use_eth: bool = False, receiver: address = msg.sender) -> uint256: nonpayable
    def coins(_i: uint256) -> address: view
    def price_oracle() -> uint256: view
    def lp_price() -> uint256: view


priority: public(HashMap[address, uint256])

receiver: public(address)
recovery: public(address)
is_killed: public(bool)

owner: public(address)
emergency_owner: public(address)
future_owner: public(address)
future_emergency_owner: public(address)


@external
def __init__(_receiver: address, _recovery: address, _owner: address, _emergency_owner: address):
    """
    @notice Contract constructor
    @dev Unlike other burners, this contract may transfer tokens to
         multiple addresses after the swap. Receiver addresses are
         set by calling `set_swap_data` instead of setting it
         within the constructor.
    @param _recovery Address that tokens are transferred to during an
                     emergency token recovery.
    @param _owner Owner address. Can kill the contract, recover tokens
                  and modify the recovery address.
    @param _emergency_owner Emergency owner address. Can kill the contract
                            and recover tokens.
    """
    self.receiver = _receiver
    self.recovery = _recovery
    self.owner = _owner
    self.emergency_owner = _emergency_owner


@payable
@external
def __default__():
    # required to receive ether
    pass


@external
def burn(_coin: address) -> bool:
    """
    @notice Convert `_coin` by removing liquidity and transfer to another burner
    @param _coin Address of the coin being converted
    @return bool success
    """
    assert not self.is_killed  # dev: is killed

    # transfer coins from caller
    amount: uint256 = ERC20(_coin).balanceOf(msg.sender)
    if amount != 0:
        ERC20(_coin).transferFrom(msg.sender, self, amount)

    # get actual balance in case of transfer fee or pre-existing balance
    amount = ERC20(_coin).balanceOf(self)

    if amount != 0:
        swap: address = CurveToken(_coin).minter()
        coins: address[2] = [CryptoSwap(swap).coins(0), CryptoSwap(swap).coins(1)]
        priorities: uint256[2] = [self.priority[coins[0]], self.priority[coins[1]]]
        assert priorities[0] > 0 or priorities[1] > 0  # dev: unknown coins

        i: uint256 = 2
        if priorities[0] > priorities[1]:
            i = 0
        elif priorities[0] < priorities[1]:
            i = 1

        if i == 2:
            # If both are equally prioritized, then remove both of them
            CryptoSwap(swap).remove_liquidity(amount, [0, 0], True, self.receiver)
        else:
            min_amount: uint256 = amount * CryptoSwap(swap).lp_price() / 10 ** 18
            if i == 1:
                min_amount = min_amount * CryptoSwap(swap).price_oracle() / 10 ** 18
            min_amount /= 10 ** (18 - ERC20(coins[i]).decimals())
            min_amount = min_amount * 98 / 100

            CryptoSwap(swap).remove_liquidity_one_coin(amount, i, min_amount, True, self.receiver)

    return True


@external
def set_priority(_coin: address, _priority: uint256):
    """
    @notice Set priority of a coin
    @dev Bigger value means higher priority
    @param _coin Token address
    @param _priority Token priority
    """
    assert msg.sender in [self.owner, self.emergency_owner]  # dev: only owner
    self.priority[_coin] = _priority


@external
def set_many_priorities(_coins: address[8], _priorities: uint256[8]):
    """
    @notice Set priority of many coins
    @dev Bigger value means higher priority
    @param _coins Token addresses
    @param _priorities Token priorities
    """
    assert msg.sender in [self.owner, self.emergency_owner]  # dev: only owner
    for i in range(8):
        coin: address = _coins[i]
        if coin == ZERO_ADDRESS:
            break
        self.priority[coin] = _priorities[i]


@external
def recover_balance(_coin: address) -> bool:
    """
    @notice Recover ERC20 tokens from this contract
    @dev Tokens are sent to the recovery address
    @param _coin Token address
    @return bool success
    """
    assert msg.sender in [self.owner, self.emergency_owner]  # dev: only owner

    amount: uint256 = ERC20(_coin).balanceOf(self)
    response: Bytes[32] = raw_call(
        _coin,
        _abi_encode(self.recovery, amount, method_id=method_id("transfer(address,uint256)")),
        max_outsize=32,
    )
    if len(response) != 0:
        assert convert(response, bool)

    return True


@external
def set_recovery(_recovery: address) -> bool:
    """
    @notice Set the token recovery address
    @param _recovery Token recovery address
    @return bool success
    """
    assert msg.sender == self.owner  # dev: only owner
    self.recovery = _recovery

    return True


@external
def set_killed(_is_killed: bool) -> bool:
    """
    @notice Set killed status for this contract
    @dev When killed, the `burn` function cannot be called
    @param _is_killed Killed status
    @return bool success
    """
    assert msg.sender in [self.owner, self.emergency_owner]  # dev: only owner
    self.is_killed = _is_killed

    return True



@external
def commit_transfer_ownership(_future_owner: address) -> bool:
    """
    @notice Commit a transfer of ownership
    @dev Must be accepted by the new owner via `accept_transfer_ownership`
    @param _future_owner New owner address
    @return bool success
    """
    assert msg.sender == self.owner  # dev: only owner
    self.future_owner = _future_owner

    return True


@external
def accept_transfer_ownership() -> bool:
    """
    @notice Accept a transfer of ownership
    @return bool success
    """
    assert msg.sender == self.future_owner  # dev: only owner
    self.owner = msg.sender

    return True


@external
def commit_transfer_emergency_ownership(_future_owner: address) -> bool:
    """
    @notice Commit a transfer of ownership
    @dev Must be accepted by the new owner via `accept_transfer_ownership`
    @param _future_owner New owner address
    @return bool success
    """
    assert msg.sender == self.emergency_owner  # dev: only owner
    self.future_emergency_owner = _future_owner

    return True


@external
def accept_transfer_emergency_ownership() -> bool:
    """
    @notice Accept a transfer of ownership
    @return bool success
    """
    assert msg.sender == self.future_emergency_owner  # dev: only owner
    self.emergency_owner = msg.sender

    return True