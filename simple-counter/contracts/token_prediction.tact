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
message StartRound {
    price: Int;
}
message BetBull {}
message BetBear {}
message EndRound {
    price: Int;
}
message EndRoundBatch {
    batchSize: Int;
}
message ClaimRewards {}
message WithdrawTreasury {}

contract TokenPrediction with Deployable {
    const STATUS_NOT_STARTED: Int = 0;
    const STATUS_LIVE: Int = 1;
    const STATUS_LOCKED: Int = 2;
    const STATUS_ENDED: Int = 3;
    const MIN_BET_AMOUNT: Int = ton("1"); // Минимальная ставка 1 TON
    const MAX_STORED_ROUNDS: Int = 1000;  // Максимальное количество хранимых раундов
    const CLEANUP_AFTER_ROUNDS: Int = 100; // Каждые 100 раундов проводим очистку

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

    fun startRound(price: Int) {
        require(sender() == self.owner, "Only admin");
        
        // Проверяем текущий раунд
        if (self.currentEpoch != 0) {
            let currentRound: Round = self.rounds.get(self.currentEpoch)!!;
            require(currentRound.status == self.STATUS_ENDED, "Current round not ended");
        }

        self.currentEpoch = self.currentEpoch + 1;
        
        // Очищаем старые данные каждые CLEANUP_AFTER_ROUNDS раундов
        if (self.currentEpoch % self.CLEANUP_AFTER_ROUNDS == 0) {
            self.cleanupOldData();
        }

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

    fun endRound(price: Int) {
        require(sender() == self.owner, "Only admin");
        let round: Round = self.rounds.get(self.currentEpoch)!!;
        
        // Проверяем, есть ли ставки с обеих сторон
        if (round.bullAmount == 0 || round.bearAmount == 0) {
            // Помечаем раунд как требующий возврата ставок
            round.status = self.STATUS_LOCKED;
            round.closePrice = price;
            self.rounds.set(self.currentEpoch, round);
            
            // Возврат ставок будет происходить через endRoundBatch
            return;
        }
        
        require(now() >= round.closeTimestamp, "Close timestamp not reached");
        round.status = self.STATUS_ENDED;
        round.closePrice = price;
        self.rounds.set(self.currentEpoch, round);
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

    receive(msg: BetBull) {
        self.placeBet(context().value, true);
    }

    receive(msg: BetBear) {
        self.placeBet(context().value, false);
    }

    fun placeBet(amount: Int, isBull: Bool) {
        require(amount >= self.MIN_BET_AMOUNT, "Bet amount too low");
        let currentRound: Round = self.rounds.get(self.currentEpoch)!!;
        require(currentRound.status == self.STATUS_LIVE, "Round not bettable");
        require(now() < currentRound.lockTimestamp, "Round locked");

        // Проверяем, не ставил ли уже пользователь в этом раунде
        let existingBet: UserBet? = self.bets.get(sender());
        require(existingBet == null || existingBet!!.epoch != self.currentEpoch, "Already placed bet in this round");

        // Сразу вычисляем и сохраняем комиссию
        let treasuryFee: Int = (amount * self.treasuryFee) / 100;
        self.treasuryBalance = self.treasuryBalance + treasuryFee;

        // Обновляем данные раунда
        currentRound.totalAmount = currentRound.totalAmount + amount;
        if (isBull) {
            currentRound.bullAmount = currentRound.bullAmount + amount;
        } else {
            currentRound.bearAmount = currentRound.bearAmount + amount;
        }

        self.rounds.set(self.currentEpoch, currentRound);
        
        // Сохраняем ставку
        let userBet: UserBet = UserBet{
            epoch: self.currentEpoch,
            amount: amount,
            isBull: isBull,
            claimed: false
        };
        self.bets.set(sender(), userBet);
    }

    receive(msg: EndRound) {
        require(sender() == self.owner, "Only admin");
        let round: Round = self.rounds.get(self.currentEpoch)!!;
        round.closePrice = msg.price;    // Сохраняем финальную цену
        round.status = self.STATUS_ENDED;  // Меняем статус
        self.rounds.set(self.currentEpoch, round);
    }

    receive(msg: EndRoundBatch) {
        self.endRoundBatch(msg.batchSize);
    }

    receive(msg: ClaimRewards) {
        self.claimRewards();
    }

    receive(msg: WithdrawTreasury) {
        self.withdrawTreasury();
    }

    fun claimRewards() {
        let sender: Address = context().sender;
        
        // Сначала рассчитываем награду за текущий раунд
        let round: Round = self.rounds.get(self.currentEpoch)!!;
        if (round.status == self.STATUS_ENDED) {
            let bet: UserBet? = self.bets.get(sender);
            if (bet != null) {
                let userBet: UserBet = bet!!;
                if (!userBet.claimed) {
                    self.claimReward(self.currentEpoch);
                }
            }
        }
        
        // Затем выплачиваем накопленные награды
        let userReward: UserRewards = self.userRewards.get(sender)!!;
        require(userReward.pendingRewards > 0, "No pending rewards");
        
        send(SendParameters{
            to: sender,
            value: userReward.pendingRewards,
            mode: SendIgnoreErrors
        });
        
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
        
        let won: Bool = round.closePrice > round.startPrice && bet.isBull || 
                       round.closePrice < round.startPrice && !bet.isBull;
        
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

    fun calculateReward(amount: Int, winningAmount: Int, totalAmount: Int): Int {
        require(winningAmount > 0, "Division by zero");
        let treasuryFee: Int = (totalAmount * self.treasuryFee) / 100;
        let rewardPool: Int = totalAmount - treasuryFee;
        return (amount * rewardPool) / winningAmount;
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
        if (round.bullAmount == 0 || round.bearAmount == 0) {
            // Возвращаем ставку
            send(SendParameters{
                to: userAddress,
                value: bet.amount,
                mode: SendIgnoreErrors
            });
        } else {
            // Обычная обработка ставки
            let won: Bool = (round.closePrice > round.startPrice && bet.isBull) || 
                          (round.closePrice < round.startPrice && !bet.isBull);
            
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
        }
        
        bet.claimed = true;
        self.bets.set(userAddress, bet);
    }

    // Новый метод для вывода комиссии
    fun withdrawTreasury() {
        require(sender() == self.owner, "Only admin");
        require(self.treasuryBalance > 0, "No treasury balance");
        
        send(SendParameters{
            to: self.owner,
            value: self.treasuryBalance,
            mode: SendIgnoreErrors
        });
        
        self.treasuryBalance = 0;
    }

    // Добавляем геттер
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

    receive(msg: StartRound) {
        self.startRound(msg.price);
    }

    get fun getCurrentEpoch(): Int {
        return self.currentEpoch;
    }

    get fun getRound(epoch: Int): Round {
        let round: Round? = self.rounds.get(epoch);
        require(round != null, "Round not found or expired");
        return round!!;
    }

    get fun getIntervalSeconds(): Int {
        return self.intervalSeconds;
    }

    fun cleanupOldData() {
        // Очищаем старые раунды
        let oldestAllowedEpoch: Int = max(1, self.currentEpoch - self.MAX_STORED_ROUNDS);
        
        repeat(self.currentEpoch) {
            self.rounds.set(oldestAllowedEpoch, null);
        }

        // Очищаем старые ставки и награды через lastProcessedAddress
        let lastAddress: Address = self.lastProcessedAddress;
        let bet: UserBet? = self.bets.get(lastAddress);
        if (bet != null && bet!!.epoch < oldestAllowedEpoch) {
            self.bets.set(lastAddress, null);
        }

        let reward: UserRewards? = self.userRewards.get(lastAddress);
        if (reward != null && reward!!.lastClaimEpoch < oldestAllowedEpoch && reward!!.pendingRewards == 0) {
            self.userRewards.set(lastAddress, null);
        }
    }

    // Добавляем helper функцию
    fun max(a: Int, b: Int): Int {
        if (a > b) {
            return a;
        }
        return b;
    }

    // Добавляем геттер для проверки доступности данных
    get fun getOldestAvailableEpoch(): Int {
        return max(1, self.currentEpoch - self.MAX_STORED_ROUNDS);
    }
}