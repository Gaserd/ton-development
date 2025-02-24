import "@stdlib/deploy";

message Withdraw {
    amount: Int as coins;
}

message Game { }

contract DiceContract with Deployable {
    const MinTonFromStorage: Int = ton("0.01");
    const MinAmountFromGame: Int = ton("0.01");
    const MaxAmountFromGame: Int = ton("1");
    const CoefficientGame: Int = 99;

    owner: Address;

    init() {
        self.owner = sender();
    }

    receive() {

    }

    fun onlyOwner() {
        require(sender() == self.owner, "only owner can witdraw all TON");
    }

    receive(msg: Game) {
        nativeRandomizeLt();
        let gameAmount: Int = myBalance();
        let addAmount: Int = context().value * self.CoefficientGame / 100;
        require(gameAmount > context().value + addAmount, "Nothing amount to the play game");
        let win: Int = randomInt();
        if (win % 2 == 0) {
            send(SendParameters{
                to : sender(),
                bounce: true,
                value : context().value + addAmount,
                mode : SendIgnoreErrors + SendRemainingValue,
            })
        } else {
            return;
        }
    }

    receive(msg: Withdraw) {
        self.onlyOwner();
        let amount: Int = min(msg.amount, myBalance() - self.MinTonFromStorage - context().value);
        require(amount>0, "Insufficient balance");
        send(SendParameters{
            to : sender(),
            bounce: true,
            value : amount,
            mode : SendIgnoreErrors + SendRemainingValue,
        })
    }

    get fun balance(): Int {
        return myBalance();
    }
}
