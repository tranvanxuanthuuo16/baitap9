module my_module::liquidity_pool {
    use sui::object::{Self as Object, UID};
    use sui::coin::{Self as Coin, Coin};
    use sui::balance::{Self as Balance, Supply, Balance};
    use sui::sui::SUI;
    use sui::transfer;
    use sui::math;
    use sui::tx_context::{Self as TxContext, TxContext};

    const ZERO_AMOUNT: u64 = 0;
    const WRONG_FEE: u64 = 1;
    const RESERVES_EMPTY: u64 = 2;
    const SHARE_EMPTY: u64 = 3;
    const POOL_FULL: u64 = 4;
    const FEE_SCALING: u128 = 10000;
    const MAX_POOL_VALUE: u64 = 18446744073709551615 / 10000;

    struct LiquidityProviderToken<PhantomP, PhantomT> has drop {}

    struct Pool<PhantomP, PhantomT> has key {
        id: UID,
        sui_balance: Balance<SUI>,
        token_balance: Balance<T>,
        lsp_supply: Supply<LiquidityProviderToken<PhantomP, PhantomT>>,
        fee_percent: u64,
    }

    #[allow(unused_function)]
    fun initialize(_: &mut TxContext) {}

    pub fun create_liquidity_pool<PhantomP: drop, PhantomT>(
        _: PhantomP,
        token: Coin<T>,
        sui: Coin<SUI>,
        fee_percent: u64,
        ctx: &mut TxContext,
    ): Coin<LiquidityProviderToken<PhantomP, PhantomT>> {
        let sui_amount = coin::value(&sui);
        let token_amount = coin::value(&token);

        assert!(sui_amount > 0 && token_amount > 0, ZERO_AMOUNT);
        assert!(sui_amount < MAX_POOL_VALUE && token_amount < MAX_POOL_VALUE, POOL_FULL);
        assert!(fee_percent >= 0 && fee_percent < 10000, WRONG_FEE);

        let share = math::sqrt(sui_amount) * math::sqrt(token_amount);
        let lsp_supply = balance::create_supply(LiquidityProviderToken {});
        let lsp = balance::increase_supply(&mut lsp_supply, share);

        transfer::share_object(Pool {
            id: object::new(ctx),
            token_balance: coin::into_balance(token),
            sui_balance: coin::into_balance(sui),
            lsp_supply,
            fee_percent,
        });

        coin::from_balance(lsp, ctx)
    }

    entry fun swap_sui_and_transfer<PhantomP, PhantomT>(
        pool: &mut Pool<PhantomP, PhantomT>, sui: Coin<SUI>, ctx: &mut TxContext,
    ) {
        transfer::public_transfer(
            swap_sui(pool, sui, ctx),
            tx_context::sender(ctx),
        );
    }

    pub fun swap_sui<PhantomP, PhantomT>(
        pool: &mut Pool<PhantomP, PhantomT>, sui: Coin<SUI>, ctx: &mut TxContext,
    ): Coin<T> {
        assert!(coin::value(&sui) > 0, ZERO_AMOUNT);

        let sui_balance = coin::into_balance(sui);
        let (sui_reserve, token_reserve, _) = get_reserves(pool);

        assert!(sui_reserve > 0 && token_reserve > 0, RESERVES_EMPTY);

        let output_amount = get_output_amount(
            balance::value(&sui_balance),
            sui_reserve,
            token_reserve,
            pool.fee_percent,
        );

        balance::join(&mut pool.sui_balance, sui_balance);
        coin::take(&mut pool.token_balance, output_amount, ctx)
    }

    entry fun swap_token_and_transfer<PhantomP, PhantomT>(
        pool: &mut Pool<PhantomP, PhantomT>, token: Coin<T>, ctx: &mut TxContext,
    ) {
        transfer::public_transfer(
            swap_token(pool, token, ctx),
            tx_context::sender(ctx),
        );
    }

    pub fun swap_token<PhantomP, PhantomT>(
        pool: &mut Pool<PhantomP, PhantomT>, token: Coin<T>, ctx: &mut TxContext,
    ): Coin<SUI> {
        assert!(coin::value(&token) > 0, ZERO_AMOUNT);

        let token_balance = coin::into_balance(token);
        let (sui_reserve, token_reserve, _) = get_reserves(pool);

        assert!(sui_reserve > 0 && token_reserve > 0, RESERVES_EMPTY);

        let output_amount = get_output_amount(
            balance::value(&token_balance),
            token_reserve,
            sui_reserve,
            pool.fee_percent,
        );

        balance::join(&mut pool.token_balance, token_balance);
        coin::take(&mut pool.sui_balance, output_amount, ctx)
    }

    entry fun add_liquidity_and_transfer<PhantomP, PhantomT>(
        pool: &mut Pool<PhantomP, PhantomT>,
        sui: Coin<SUI>,
        token: Coin<T>,
        ctx: &mut TxContext,
    ) {
        transfer::public_transfer(
            add_liquidity(pool, sui, token, ctx),
            tx_context::sender(ctx),
        );
    }

    pub fun add_liquidity<PhantomP, PhantomT>(
        pool: &mut Pool<PhantomP, PhantomT>,
        sui: Coin<SUI>,
        token: Coin<T>,
        ctx: &mut TxContext,
    ): Coin<LiquidityProviderToken<PhantomP, PhantomT>> {
        assert!(coin::value(&sui) > 0, ZERO_AMOUNT);
        assert!(coin::value(&token) > 0, ZERO_AMOUNT);

        let sui_balance = coin::into_balance(sui);
        let token_balance = coin::into_balance(token);

        let (sui_amount, token_amount, lsp_supply) = get_reserves(pool);

        let sui_added = balance::value(&sui_balance);
        let token_added = balance::value(&token_balance);
        let share_minted = math::min(
            (sui_added * lsp_supply) / sui_amount,
            (token_added * lsp_supply) / token_amount,
        );

        let sui_amt = balance::join(&mut pool.sui_balance, sui_balance);
        let token_amt = balance::join(&mut pool.token_balance, token_balance);

        assert!(sui_amt < MAX_POOL_VALUE, POOL_FULL);
        assert!(token_amt < MAX_POOL_VALUE, POOL_FULL);

        let balance = balance::increase_supply(&mut pool.lsp_supply, share_minted);
        coin::from_balance(balance, ctx)
    }

    entry fun remove_liquidity_and_transfer<PhantomP, PhantomT>(
        pool: &mut Pool<PhantomP, PhantomT>,
        lsp: Coin<LiquidityProviderToken<PhantomP, PhantomT>>,
        ctx: &mut TxContext,
    ) {
        let (sui, token) = remove_liquidity(pool, lsp, ctx);
        let sender = tx_context::sender(ctx);

        transfer::public_transfer(sui, sender);
        transfer::public_transfer(token, sender);
    }

    pub fun remove_liquidity<PhantomP, PhantomT>(
        pool: &mut Pool<PhantomP, PhantomT>,
        lsp: Coin<LiquidityProviderToken<PhantomP, PhantomT>>,
        ctx: &mut TxContext,
    ): (Coin<SUI>, Coin<T>) {
        let lsp_amount = coin::value(&lsp);

        assert!(lsp_amount > 0, ZERO_AMOUNT);

        let (sui_amt, token_amt, lsp_supply) = get_reserves(pool);
        let sui_removed = (sui_amt * lsp_amount) / lsp_supply;
        let token_removed = (token_amt * lsp_amount) / lsp_supply;

        balance::decrease_supply(&mut pool.lsp_supply, coin::into_balance(lsp));

        (
            coin::take(&mut pool.sui_balance, sui_removed, ctx),
            coin::take(&mut pool.token_balance, token_removed, ctx),
        )
    }

    pub fun get_sui_price<PhantomP, PhantomT>(pool: &Pool<PhantomP, PhantomT>, to_sell: u64): u64 {
        let (sui_amt, token_amt, _) = get_reserves(pool);
        get_input_price(to_sell, token_amt, sui_amt, pool.fee_percent)
    }

    pub fun get_token_price<PhantomP, PhantomT>(pool: &Pool<PhantomP, PhantomT>, to_sell: u64): u64 {
        let (sui_amt, token_amt, _) = get_reserves(pool);
        get_input_price(to_sell, sui_amt, token_amt, pool.fee_percent)
    }

    pub fun get_reserves<PhantomP, PhantomT>(pool: &Pool<PhantomP, PhantomT>): (u64, u64, u64) {
        (
            balance::value(&pool.sui_balance),
            balance::value(&pool.token_balance),
            balance::supply_value(&pool.lsp_supply),
        )
    }

    pub fun get_input_price(
        input_amount: u64,
        input_reserve: u64,
        output_reserve: u64,
        fee_percent: u64,
    ): u64 {
        let (
            input_amount,
            input_reserve,
            output_reserve,
            fee_percent,
        ) = (
            input_amount as u128,
            input_reserve as u128,
            output_reserve as u128,
            fee_percent as u128,
        );

        let input_amount_with_fee = input_amount * (FEE_SCALING - fee_percent);
        let numerator = input_amount_with_fee * output_reserve;
        let denominator = (input_reserve * FEE_SCALING) + input_amount_with_fee;

        (numerator / denominator as u64)
    }
}
