package com.notel.notel.data.billing

import android.app.Activity
import android.content.Context
import android.util.Log
import com.android.billingclient.api.*
import com.notel.notel.data.preferences.NotelPreferences
import com.notel.notel.data.remote.BillingVerificationRequest
import com.notel.notel.data.remote.JotApi
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class BillingManager @Inject constructor(
    @ApplicationContext private val context: Context,
    private val preferences: NotelPreferences,
    private val jotApi: JotApi
) : PurchasesUpdatedListener {

    private val tag = "BillingManager"
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    
    // Flow to notify UI of status changes or errors
    private val _billingEvents = MutableSharedFlow<String>()
    val billingEvents: SharedFlow<String> = _billingEvents

    private var billingClient = BillingClient.newBuilder(context)
        .setListener(this)
        .enablePendingPurchases(PendingPurchasesParams.newBuilder().enableOneTimeProducts().build())
        .build()

    init {
        startConnection()
    }

    private fun startConnection() {
        Log.d(tag, "Starting BillingClient connection...")
        billingClient.startConnection(object : BillingClientStateListener {
            override fun onBillingSetupFinished(billingResult: BillingResult) {
                if (billingResult.responseCode == BillingClient.BillingResponseCode.OK) {
                    Log.d(tag, "BillingClient setup finished successfully")
                    queryAvailableProducts()
                } else {
                    Log.e(tag, "BillingClient setup failed: ${billingResult.debugMessage}")
                }
            }

            override fun onBillingServiceDisconnected() {
                Log.w(tag, "BillingClient disconnected. Retrying...")
                startConnection()
            }
        })
    }

    private val productList = listOf(
        QueryProductDetailsParams.Product.newBuilder()
            .setProductId("jot_membership_monthly")
            .setProductType(BillingClient.ProductType.SUBS)
            .build(),
        QueryProductDetailsParams.Product.newBuilder()
            .setProductId("jot_credits_5")
            .setProductType(BillingClient.ProductType.INAPP)
            .build(),
        QueryProductDetailsParams.Product.newBuilder()
            .setProductId("jot_credits_10")
            .setProductType(BillingClient.ProductType.INAPP)
            .build(),
        QueryProductDetailsParams.Product.newBuilder()
            .setProductId("jot_credit_unit")
            .setProductType(BillingClient.ProductType.INAPP)
            .build()
    )

    private val productDetailsMap = mutableMapOf<String, ProductDetails>()

    private fun queryAvailableProducts() {
        val params = QueryProductDetailsParams.newBuilder()
            .setProductList(productList)
            .build()

        billingClient.queryProductDetailsAsync(params) { billingResult, productDetailsList ->
            if (billingResult.responseCode == BillingClient.BillingResponseCode.OK) {
                Log.d(tag, "Query successful. Found ${productDetailsList.size} products")
                productDetailsList.forEach {
                    productDetailsMap[it.productId] = it
                    Log.d(tag, "Found product: ${it.productId} - ${it.name}")
                }
            } else {
                Log.e(tag, "Query failed: ${billingResult.debugMessage}")
            }
        }
    }

    /**
     * Launch the billing flow for a specific product ID with an optional quantity.
     */
    fun launchPurchaseFlow(activity: Activity, productId: String, quantity: Int = 1) {
        val productDetails = productDetailsMap[productId]
        if (productDetails == null) {
            Log.e(tag, "Product details not found for $productId")
            scope.launch { _billingEvents.emit("Product not available in Play Store.") }
            return
        }

        val productDetailsParamsBuilder = BillingFlowParams.ProductDetailsParams.newBuilder()
            .setProductDetails(productDetails)

        if (productDetails.productType == BillingClient.ProductType.SUBS) {
            val offerToken = productDetails.subscriptionOfferDetails?.firstOrNull()?.offerToken
            if (offerToken != null) {
                productDetailsParamsBuilder.setOfferToken(offerToken)
            }
        }

        val productDetailsParamsList = listOf(productDetailsParamsBuilder.build())

        val flowParams = BillingFlowParams.newBuilder()
            .setProductDetailsParamsList(productDetailsParamsList)
            .build()

        billingClient.launchBillingFlow(activity, flowParams)
    }

    override fun onPurchasesUpdated(billingResult: BillingResult, purchases: List<Purchase>?) {
        if (billingResult.responseCode == BillingClient.BillingResponseCode.OK && purchases != null) {
            for (purchase in purchases) {
                handlePurchase(purchase)
            }
        } else if (billingResult.responseCode == BillingClient.BillingResponseCode.USER_CANCELED) {
            Log.i(tag, "User canceled the purchase flow")
        } else {
            Log.e(tag, "Purchase failed: ${billingResult.debugMessage}")
            scope.launch { _billingEvents.emit("Purchase failed: ${billingResult.debugMessage}") }
        }
    }

    private fun handlePurchase(purchase: Purchase) {
        if (purchase.purchaseState == Purchase.PurchaseState.PURCHASED) {
            // Send to our server for verification
            verifyWithServer(purchase)
        }
    }

    private fun verifyWithServer(purchase: Purchase) {
        scope.launch {
            try {
                // Since a purchase can contain multiple products, but for INAPP it's usually one
                val productId = purchase.products.firstOrNull() ?: return@launch
                
                val response = jotApi.verifyPurchase(
                    BillingVerificationRequest(
                        productId = productId,
                        purchaseToken = purchase.purchaseToken,
                        quantity = purchase.quantity
                    )
                )

                if (response.isSuccessful && response.body()?.success == true) {
                    val newBalance = response.body()?.balance ?: 0f
                    preferences.setUserBalance(newBalance)
                    
                    // Acknowledge the purchase if it hasn't been yet
                    if (!purchase.isAcknowledged) {
                        val acknowledgeParams = AcknowledgePurchaseParams.newBuilder()
                            .setPurchaseToken(purchase.purchaseToken)
                            .build()
                        billingClient.acknowledgePurchase(acknowledgeParams) { result ->
                            if (result.responseCode == BillingClient.BillingResponseCode.OK) {
                                Log.d(tag, "Purchase acknowledged successfully")
                                scope.launch { _billingEvents.emit("Success! Credits added.") }
                            }
                        }
                    } else {
                        _billingEvents.emit("Success! Credits updated.")
                    }
                    
                    // Important: Consume the purchase so it can be bought again
                    // Since these are "Credits", they should be consumable.
                    consumePurchase(purchase)
                    
                } else {
                    Log.e(tag, "Server verification failed: ${response.message()}")
                    _billingEvents.emit("Payment verification failed on server.")
                }
            } catch (e: Exception) {
                Log.e(tag, "Error verifying purchase: ${e.message}")
                _billingEvents.emit("Connection error during payment verification.")
            }
        }
    }

    private fun consumePurchase(purchase: Purchase) {
        val consumeParams = ConsumeParams.newBuilder()
            .setPurchaseToken(purchase.purchaseToken)
            .build()
        
        billingClient.consumeAsync(consumeParams) { result, _ ->
            if (result.responseCode == BillingClient.BillingResponseCode.OK) {
                Log.d(tag, "Purchase consumed successfully")
            } else {
                Log.e(tag, "Consume failed: ${result.debugMessage}")
            }
        }
    }
}
