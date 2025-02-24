import "@stdlib/deploy";
struct Round {
    epoch: Int; // Номер раунда
    status: Int; // Статус раунда
    startPrice: Int; // Начальная цена
    lockPrice: Int; // Цена при блокировке
    closePrice: Int; // Конечная цена
    lockTimestamp: Int; // Время блокировки
    closeTimestamp: Int; // Время закрытия
    totalAmount: Int; // Общая сумма ставок
    bullAmount: Int; // Сумма ставок на повышение
    bearAmount: Int; // Сумма ставок на понижение
}
struct UserBet {
    epoch: Int; // Номер раунда
    amount: Int; // Размер ставки
    isBull: Bool; // true - ставка на повышение, false - на понижение
    claimed: Bool; // Получен ли выигрыш
}
struct PriceData {
    price: Int;
    timestamp: Int;
}
struct UserRewards {
    pendingRewards: Int;     // Сумма невыплаченных выигрышей
    claimedRewards: Int;     // Сумма уже выплаченных выигрышей
    lastClaimEpoch: Int;     // Последняя эпоха, в которой был получен выигрыш
}
message GetPriceMessage {
    query_id: Int;
}
message PriceResponse {
    query_id: Int;
    price: Int;
}
message UpdateTreasuryFee {
    new_fee: Int;
}
message SetDeDustPair {
    new_pair: Address;
}

contract TokenPrediction with Deployable {
    const STATUS_NOT_STARTED: Int = 0;
    const STATUS_LIVE: Int = 1;
    const STATUS_LOCKED: Int = 2;
    const STATUS_ENDED: Int = 3;

    owner: Address; // Адрес владельца контракта
    currentEpoch: Int; // Текущий номер раунда
    minBetAmount: Int; // Минимальная сумма ставки
    intervalSeconds: Int; // Длительность раунда в секундах
    treasuryFee: Int; // Комиссия (в процентах)
    dedust_pair: Address; // Адрес пары TON/USDT на DeDust
    lastPrice: PriceData; // Последняя полученная цена
    priceValidityPeriod: Int; // Период валидности цены
    rounds: map<Int, Round>; // Хранение информации о раундах
    bets: map<Address, UserBet>; // Хранение ставок пользователей
    userRewards: map<Address, UserRewards>; //маппинг для хранения наград пользователей
    lastProcessedAddress: Address;
    treasuryBalance: Int;  // Накопленная комиссия

    init(){
        self.owner = sender();
        self.currentEpoch = 0;
        self.minBetAmount = ton("0.1");
        self.intervalSeconds = 300;
        self.treasuryFee = 3;
        self.dedust_pair = address("EQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAM9c");
        self.priceValidityPeriod = 60;
        self.lastPrice = PriceData{price: 0, timestamp: 0};
        self.lastProcessedAddress = self.owner;
        self.treasuryBalance = 0;
    }

    fun getPrice(): Int {
        let currentTime: Int = now();
        if ((currentTime - self.lastPrice.timestamp) < self.priceValidityPeriod) {
            return self.lastPrice.price;
        }
        send(SendParameters{
                to: self.dedust_pair,
                value: ton("0.1"),
                mode: SendIgnoreErrors,
                body: GetPriceMessage{query_id: currentTime}.toCell()
            }
        );
        return self.lastPrice.price;
    }

    receive(msg: PriceResponse){
        require(sender() == self.dedust_pair, "Invalid price oracle");
        self.lastPrice = PriceData{price: msg.price, timestamp: now()};
    }

    fun genesisStartRound() {
        require(sender() == self.owner, "Only admin");
        require(self.currentEpoch == 0, "Can only run genesis round once");
        let price: Int = self.getPrice();
        self.currentEpoch = self.currentEpoch + 1;
        let currentTimestamp: Int = now();
        let genesisRound: Round = Round{
            epoch: self.currentEpoch,
            status: self.STATUS_LIVE,
            startPrice: price,
            lockPrice: 0,
            closePrice: 0,
            lockTimestamp: currentTimestamp + self.intervalSeconds,
            closeTimestamp: currentTimestamp + (self.intervalSeconds * 2),
            totalAmount: 0,
            bullAmount: 0,
            bearAmount: 0
        };
        self.rounds.set(self.currentEpoch, genesisRound);
    }

    fun startRound() {
        require(sender() == self.owner, "Only admin");
        
        // Проверяем текущий раунд только если это не первый раунд
        if (self.currentEpoch != 0) {
            let currentRound: Round = self.rounds.get(self.currentEpoch)!!;
            require(currentRound.status == self.STATUS_ENDED, "Current round not ended");
        }

        let price: Int = self.getPrice();
        self.currentEpoch = self.currentEpoch + 1;
        let currentTimestamp: Int = now();
        
        let newRound: Round = Round{
            epoch: self.currentEpoch,
            status: self.STATUS_LIVE,
            startPrice: price,
            lockPrice: 0,
            closePrice: 0,
            lockTimestamp: currentTimestamp + self.intervalSeconds,
            closeTimestamp: currentTimestamp + (self.intervalSeconds * 2),
            totalAmount: 0,
            bullAmount: 0,
            bearAmount: 0
        };
        
        self.rounds.set(self.currentEpoch, newRound);
    }

    fun lockRound() {
        require(sender() == self.owner, "Only admin");
        let currentRound: Round = self.rounds.get(self.currentEpoch)!!;
        require(currentRound.status == self.STATUS_LIVE, "Round not live");
        require(now() >= currentRound.lockTimestamp, "Lock timestamp not reached");
        let price: Int = self.getPrice();
        currentRound.status = self.STATUS_LOCKED;
        currentRound.lockPrice = price;
        self.rounds.set(self.currentEpoch, currentRound);
    }

    fun endRound() {
        require(sender() == self.owner, "Only admin");
        let currentRound: Round = self.rounds.get(self.currentEpoch)!!;
        require(currentRound.status == self.STATUS_LOCKED, "Round not locked");
        require(now() >= currentRound.closeTimestamp, "Close timestamp not reached");
        
        let price: Int = self.getPrice();
        currentRound.status = self.STATUS_ENDED;
        currentRound.closePrice = price;
        
        self.rounds.set(self.currentEpoch, currentRound);
    }

    fun endRoundBatch(batchSize: Int) {
        require(sender() == self.owner, "Only admin");
        let currentRound: Round = self.rounds.get(self.currentEpoch)!!;
        require(currentRound.status == self.STATUS_LOCKED || currentRound.status == self.STATUS_ENDED, "Round not locked");
        
        let users: map<Address, UserBet> = self.bets;
        let processed: Int = 0;
        let currentAddress: Address = self.lastProcessedAddress;
        
        repeat(batchSize) {
            let bet: UserBet? = users.get(currentAddress);
            if (bet != null) {
                let bet_value: UserBet = bet!!;
                if (bet_value.epoch == self.currentEpoch && !bet_value.claimed) {
                    self.processBet(currentAddress, bet_value, currentRound);
                    processed = processed + 1;
                }
            }
            self.lastProcessedAddress = currentAddress;
        }
        
        if (processed < batchSize) {
            currentRound.status = self.STATUS_ENDED;
            self.rounds.set(self.currentEpoch, currentRound);
            
            // Накапливаем комиссию вместо мгновенной отправки
            let feeAmount: Int = (currentRound.totalAmount * self.treasuryFee) / 100;
            if (feeAmount > 0) {
                self.treasuryBalance = self.treasuryBalance + feeAmount;
            }
        }
    }

    receive("bet_bull"){
        let amount: Int = context().value;
        self.placeBet(amount, true);
    }

    receive("bet_bear"){
        let amount: Int = context().value;
        self.placeBet(amount, false);
    }

    fun placeBet(amount: Int, isBull: Bool) {
        require(amount >= self.minBetAmount, "Bet amount too small");
        let currentRound: Round = self.rounds.get(self.currentEpoch)!!;
        require(currentRound.status == self.STATUS_LIVE, "Round not bettable");
        require(now() < currentRound.lockTimestamp, "Round locked");
        currentRound.totalAmount = currentRound.totalAmount + amount;
        if (isBull) {
            currentRound.bullAmount = currentRound.bullAmount + amount;
        } else {
            currentRound.bearAmount = currentRound.bearAmount + amount;
        }
        self.rounds.set(self.currentEpoch, currentRound);
        let userBets: UserBet = self.bets.get(sender())!!;
        userBets = UserBet {epoch: self.currentEpoch, amount: amount, isBull: isBull, claimed: false};
        self.bets.set(sender(), userBets);
    }

    receive("claim_all_rewards") {
        let sender: Address = context().sender;
        let defaultReward: UserRewards = UserRewards{
            pendingRewards: 0,
            claimedRewards: 0,
            lastClaimEpoch: 0
        };
        let maybeReward: UserRewards? = self.userRewards.get(sender);
        let userReward: UserRewards = defaultReward;
        if (maybeReward != null) {
            userReward = maybeReward!!;
        }
        
        require(userReward.pendingRewards > 0, "No pending rewards");
        
        // Отправляем все накопленные награды
        send(SendParameters{
            to: sender,
            value: userReward.pendingRewards,
            mode: SendIgnoreErrors
        });
        
        // Обновляем статистику наград
        userReward.claimedRewards = userReward.claimedRewards + userReward.pendingRewards;
        userReward.pendingRewards = 0;
        userReward.lastClaimEpoch = self.currentEpoch;
        
        self.userRewards.set(sender, userReward);
    }

    fun claimReward(epoch: Int) {
        let round: Round = self.rounds.get(epoch)!!;
        require(round.status == self.STATUS_ENDED, "Round not ended");
        let bet: UserBet = self.bets.get(sender())!!;
        require(bet.epoch == epoch, "No bet for this epoch");
        require(bet.claimed == false, "Rewards already claimed");
        
        let won: Bool = round.closePrice > round.lockPrice && bet.isBull || 
                       round.closePrice < round.lockPrice && !bet.isBull;
        
        if (won) {
            let rewardAmount: Int = self.calculateReward(
                bet.amount,
                bet.isBull ? round.bullAmount : round.bearAmount,
                round.totalAmount
            );
            
            // Обновляем награды пользователя вместо прямой отправки
            let maybeReward: UserRewards? = self.userRewards.get(sender());
            let defaultReward: UserRewards = UserRewards{
                pendingRewards: 0,
                claimedRewards: 0,
                lastClaimEpoch: 0
            };
            let userReward: UserRewards = defaultReward;
            if (maybeReward != null) {
                userReward = maybeReward!!;
            }
            
            userReward.pendingRewards = userReward.pendingRewards + rewardAmount;
            self.userRewards.set(sender(), userReward);
            
            // Помечаем ставку как выплаченную
            bet.claimed = true;
            self.bets.set(sender(), bet);
        }
    }

    fun calculateReward(amount: Int, poolAmount: Int, totalAmount: Int): Int {
        let feeAmount: Int = (totalAmount * self.treasuryFee) / 100;
        let rewardPool: Int = totalAmount - feeAmount;
        return (amount * rewardPool) / poolAmount;
    }

    fun updateDeDustPair(newPair: Address) {
        require(sender() == self.owner, "Only admin");
        self.dedust_pair = newPair;
    }

    fun updatePriceValidityPeriod(newPeriod: Int) {
        require(sender() == self.owner, "Only admin");
        require(newPeriod > 0, "Invalid period");
        self.priceValidityPeriod = newPeriod;
    }

    get fun getUserRewards(user: Address): UserRewards {
        let maybeReward: UserRewards? = self.userRewards.get(user);
        let defaultReward: UserRewards = UserRewards{
            pendingRewards: 0,
            claimedRewards: 0,
            lastClaimEpoch: 0
        };
        let userReward: UserRewards = defaultReward;
        if (maybeReward != null) {
            userReward = maybeReward!!;
        }
        return userReward;
    }

    fun processBet(userAddress: Address, bet: UserBet, round: Round) {
        let won: Bool = (round.closePrice > round.lockPrice && bet.isBull) || 
                       (round.closePrice < round.lockPrice && !bet.isBull);
        
        if (won) {
            let rewardAmount: Int = self.calculateReward(
                bet.amount,
                bet.isBull ? round.bullAmount : round.bearAmount,
                round.totalAmount
            );
            
            let userReward: UserRewards = self.getUserRewards(userAddress);
            userReward.pendingRewards = userReward.pendingRewards + rewardAmount;
            self.userRewards.set(userAddress, userReward);
        }
        
        bet.claimed = true;
        self.bets.set(userAddress, bet);
    }

    // Новый метод для вывода комиссии
    receive("withdraw_treasury") {
        require(sender() == self.owner, "Only admin");
        require(self.treasuryBalance > 0, "No treasury balance");
        
        send(SendParameters{
            to: self.owner,
            value: self.treasuryBalance,
            mode: SendIgnoreErrors
        });
        
        self.treasuryBalance = 0;
    }

    // Геттер для просмотра накопленной комиссии
    get fun getTreasuryBalance(): Int {
        return self.treasuryBalance;
    }

    // Добавить возможность изменения комиссии
    fun updateTreasuryFee(newFee: Int) {
        require(sender() == self.owner, "Only admin");
        require(newFee >= 0 && newFee <= 10, "Invalid fee percentage");
        self.treasuryFee = newFee;
    }

    // Добавляем receive-функцию
    receive(msg: UpdateTreasuryFee) {
        self.updateTreasuryFee(msg.new_fee);
    }

    receive(msg: SetDeDustPair) {
        require(sender() == self.owner, "Only admin");
        self.dedust_pair = msg.new_pair;
    }
}