package com.notel.notel.ui.screen

import androidx.compose.animation.*
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.notel.notel.R
import com.notel.notel.data.preferences.NotelPreferences
import com.notel.notel.data.remote.AuthRequest
import com.notel.notel.data.remote.ForgotPasswordRequest
import com.notel.notel.data.remote.TabsApi
import com.notel.notel.data.sync.SyncManager
import com.notel.notel.ui.theme.*
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.json.Json
import javax.inject.Inject

@HiltViewModel
class LoginViewModel @Inject constructor(
    private val preferences: NotelPreferences,
    private val tabsApi: TabsApi,
    private val syncManager: SyncManager
) : ViewModel() {
    var isLoggedIn by mutableStateOf<Boolean?>(null)
        private set

    var errorMsg by mutableStateOf<String?>(null)
        private set
        
    var isLoading by mutableStateOf(false)
        private set

    var onboardingCompleteByServer by mutableStateOf<Boolean?>(null)
        private set

    init {
        viewModelScope.launch {
            val alreadyLoggedIn = preferences.loggedIn.first()
            if (alreadyLoggedIn) {
                val cachedOnboarding = preferences.onboardingComplete.first()
                onboardingCompleteByServer = cachedOnboarding
                isLoggedIn = true
                
                viewModelScope.launch {
                    try {
                        syncManager.pullAllData()
                    } catch (e: Exception) {
                    }
                }
            } else {
                isLoggedIn = false
            }
        }
    }

    var successMsg by mutableStateOf<String?>(null)
        private set

    fun setError(msg: String?) {
        errorMsg = msg
    }

    fun setSuccess(msg: String?) {
        successMsg = msg
    }

    fun forgotPassword(email: String) {
        if (email.isBlank()) {
            errorMsg = "Please enter your email to reset password"
            return
        }

        viewModelScope.launch {
            isLoading = true
            errorMsg = null
            successMsg = null
            
            try {
                val response = tabsApi.forgotPassword(ForgotPasswordRequest(email))
                val body = response.body()
                
                if (response.isSuccessful && body?.success == true) {
                    successMsg = body.message ?: "Reset link sent to your email"
                } else {
                    errorMsg = body?.error ?: "Failed to send reset link"
                }
            } catch (e: Exception) {
                errorMsg = e.message ?: "Network error"
            } finally {
                isLoading = false
            }
        }
    }

    fun login(email: String, pass: String) {
        if (email.isBlank() || pass.isBlank()) {
            errorMsg = "Please fill in all fields"
            return
        }
        
        viewModelScope.launch {
            isLoading = true
            errorMsg = null
            
            try {
                val response = tabsApi.login(AuthRequest(email, pass))
                val body = response.body()
                
                if (response.isSuccessful && body != null && body.token?.isNotBlank() == true) {
                    preferences.setAuthToken(body.token!!)
                    preferences.setLoggedIn(true)
                    
                    body.isUnlimited?.let { preferences.setIsUnlimited(it) }
                    body.isAdmin?.let { preferences.setIsAdmin(it) }
                    body.onboardingComplete?.let { 
                        if (it) {
                            preferences.setOnboardingComplete(true)
                            preferences.setCupTheorySeen(true)
                        }
                    }
                    body.nickname?.let { preferences.setUserNickname(it) }
                    body.tag?.let { preferences.setUserTag(it) }
                    
                    syncManager.pullAllData()
                    
                    onboardingCompleteByServer = preferences.onboardingComplete.first()
                    isLoggedIn = true
                } else {
                    val errorBody = response.errorBody()?.string()
                    val errorMessage = try {
                        if (errorBody != null) {
                            val json = Json { ignoreUnknownKeys = true }
                            json.decodeFromString<com.notel.notel.data.remote.AuthResponse>(errorBody).error
                        } else null
                    } catch (e: Exception) { null }
                    
                    errorMsg = errorMessage ?: (body?.error ?: "Invalid credentials")
                }
            } catch (e: Exception) {
                errorMsg = e.message ?: "Network error"
            } finally {
                isLoading = false
            }
        }
    }

    fun loginWithGoogleAccount(email: String) {
        viewModelScope.launch {
            isLoading = true
            errorMsg = null
            try {
                val response = tabsApi.login(AuthRequest(email, "GoogleAuthPass!2026"))
                val body = response.body()
                
                if (response.isSuccessful && body != null && body.token?.isNotBlank() == true) {
                    preferences.setAuthToken(body.token!!)
                    preferences.setLoggedIn(true)
                    body.isUnlimited?.let { preferences.setIsUnlimited(it) }
                    body.isAdmin?.let { preferences.setIsAdmin(it) }
                    body.onboardingComplete?.let { 
                        if (it) {
                            preferences.setOnboardingComplete(true)
                            preferences.setCupTheorySeen(true)
                        }
                    }
                    body.nickname?.let { preferences.setUserNickname(it) }
                    body.tag?.let { preferences.setUserTag(it) }
                    syncManager.pullAllData()
                    onboardingCompleteByServer = preferences.onboardingComplete.first()
                    isLoggedIn = true
                } else {
                    register(email, "GoogleAuthPass!2026")
                }
            } catch (e: Exception) {
                register(email, "GoogleAuthPass!2026")
            } finally {
                isLoading = false
            }
        }
    }

    fun register(email: String, pass: String) {
        if (email.isBlank() || pass.isBlank()) {
            errorMsg = "Please fill in all fields"
            return
        }
        
        viewModelScope.launch {
            isLoading = true
            errorMsg = null
            
            try {
                val response = tabsApi.register(AuthRequest(email, pass))
                val body = response.body()
                
                if (response.isSuccessful && body != null && body.token?.isNotBlank() == true) {
                    preferences.setAuthToken(body.token!!)
                    preferences.setLoggedIn(true)
                    body.nickname?.let { preferences.setUserNickname(it) }
                    body.tag?.let { preferences.setUserTag(it) }
                    onboardingCompleteByServer = false
                    isLoggedIn = true
                } else {
                    val errorStr = response.errorBody()?.string() ?: ""
                    val errorMessage = try {
                        if (errorStr.contains("\"error\":")) {
                           errorStr.substringAfter("\"error\":\"").substringBefore("\"")
                        } else null
                    } catch (e: Exception) { null }
                    
                    errorMsg = errorMessage ?: (body?.error ?: "Registration failed")
                }
            } catch (e: Exception) {
                errorMsg = e.message ?: "Network error"
            } finally {
                isLoading = false
            }
        }
    }
}

@OptIn(ExperimentalLayoutApi::class, ExperimentalMaterial3Api::class)
@Composable
fun LoginScreen(
    initialMode: String = "register",
    onBack: () -> Unit,
    viewModel: LoginViewModel = hiltViewModel(),
    onLoginSuccess: (Boolean) -> Unit
) {
    var email by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var isRegisterMode by remember { mutableStateOf(initialMode == "register") }
    var isForgotPasswordMode by remember { mutableStateOf(false) }
    var passwordVisible by remember { mutableStateOf(false) }
    
    val context = androidx.compose.ui.platform.LocalContext.current
    val loggedIn = viewModel.isLoggedIn
    val errorMsg = viewModel.errorMsg
    val successMsg = viewModel.successMsg
    val isLoading = viewModel.isLoading

    val googleAccountLauncher = androidx.activity.compose.rememberLauncherForActivityResult(
        contract = androidx.activity.result.contract.ActivityResultContracts.StartActivityForResult()
    ) { result ->
        if (result.resultCode == android.app.Activity.RESULT_OK && result.data != null) {
            val accountName = result.data?.getStringExtra(android.accounts.AccountManager.KEY_ACCOUNT_NAME)
            if (!accountName.isNullOrBlank()) {
                viewModel.loginWithGoogleAccount(accountName)
            }
        }
    }

    LaunchedEffect(loggedIn, viewModel.onboardingCompleteByServer) {
        if (loggedIn == true && viewModel.onboardingCompleteByServer != null) {
            onLoginSuccess(viewModel.onboardingCompleteByServer!!)
        }
    }

    if (loggedIn == null || (loggedIn == true && viewModel.onboardingCompleteByServer == null)) {
        Box(modifier = Modifier.fillMaxSize().padding(16.dp), contentAlignment = Alignment.Center) {
            GlassySpinner(size = 48.dp)
        }
        return
    }

    Scaffold(
        containerColor = NotelBackground
    ) { padding ->
        Box(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
        ) {
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .verticalScroll(rememberScrollState())
                    .padding(horizontal = 24.dp, vertical = 16.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.Center
            ) {
                TopLogoHeader(
                    onBack = onBack,
                    modifier = Modifier.padding(top = 8.dp)
                )

                Spacer(Modifier.height(24.dp))

                Surface(
                    shape = RoundedCornerShape(28.dp),
                    color = NotelSurface,
                    shadowElevation = 8.dp,
                    border = BorderStroke(1.dp, NotelPrimary.copy(alpha = 0.15f)),
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Column(
                        modifier = Modifier.padding(24.dp),
                        horizontalAlignment = Alignment.CenterHorizontally
                    ) {
                        // HEADER TITLE (Log In or Sign Up)
                        Text(
                            text = when {
                                isForgotPasswordMode -> "Reset Password"
                                isRegisterMode -> "Create Your Account"
                                else -> "Welcome Back"
                            },
                            fontSize = 22.sp,
                            fontWeight = FontWeight.Bold,
                            color = NotelTextPrimary,
                            textAlign = TextAlign.Center
                        )

                        Spacer(Modifier.height(20.dp))

                        // EMAIL TEXT FIELD
                        OutlinedTextField(
                            value = email,
                            onValueChange = { email = it; viewModel.setError(null) },
                            label = { Text("Email Address") },
                            leadingIcon = { Icon(Icons.Default.Email, contentDescription = null, tint = NotelTextSecondary) },
                            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Email),
                            singleLine = true,
                            colors = OutlinedTextFieldDefaults.colors(
                                focusedBorderColor = NotelPrimary,
                                unfocusedBorderColor = NotelTextSecondary.copy(alpha = 0.4f),
                                focusedLabelColor = NotelPrimary,
                                unfocusedLabelColor = NotelTextSecondary
                            ),
                            shape = RoundedCornerShape(14.dp),
                            modifier = Modifier.fillMaxWidth()
                        )

                        if (!isForgotPasswordMode) {
                            Spacer(Modifier.height(12.dp))

                            OutlinedTextField(
                                value = password,
                                onValueChange = { password = it; viewModel.setError(null) },
                                label = { Text("Password") },
                                leadingIcon = { Icon(Icons.Default.Lock, contentDescription = null, tint = NotelTextSecondary) },
                                trailingIcon = {
                                    IconButton(onClick = { passwordVisible = !passwordVisible }) {
                                        Icon(
                                            imageVector = if (passwordVisible) Icons.Default.Visibility else Icons.Default.VisibilityOff,
                                            contentDescription = null,
                                            tint = NotelTextSecondary
                                        )
                                    }
                                },
                                visualTransformation = if (passwordVisible) VisualTransformation.None else PasswordVisualTransformation(),
                                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
                                singleLine = true,
                                colors = OutlinedTextFieldDefaults.colors(
                                    focusedBorderColor = NotelPrimary,
                                    unfocusedBorderColor = NotelTextSecondary.copy(alpha = 0.4f),
                                    focusedLabelColor = NotelPrimary,
                                    unfocusedLabelColor = NotelTextSecondary
                                ),
                                shape = RoundedCornerShape(14.dp),
                                modifier = Modifier.fillMaxWidth()
                            )
                        }

                        if (errorMsg != null) {
                            Spacer(Modifier.height(12.dp))
                            Text(
                                text = errorMsg,
                                color = MaterialTheme.colorScheme.error,
                                fontSize = 13.sp,
                                textAlign = TextAlign.Center,
                                modifier = Modifier.fillMaxWidth()
                            )
                        }

                        if (successMsg != null) {
                            Spacer(Modifier.height(12.dp))
                            Text(
                                text = successMsg,
                                color = Color(0xFF4CAF50),
                                fontSize = 13.sp,
                                textAlign = TextAlign.Center,
                                modifier = Modifier.fillMaxWidth()
                            )
                        }

                        Spacer(Modifier.height(20.dp))

                        // SUBMIT BUTTON (Log In / Create Account)
                        GlassyButton(
                            onClick = {
                                if (isForgotPasswordMode) {
                                    viewModel.forgotPassword(email)
                                } else if (isRegisterMode) {
                                    viewModel.register(email, password)
                                } else {
                                    viewModel.login(email, password)
                                }
                            },
                            enabled = !isLoading,
                            modifier = Modifier
                                .fillMaxWidth()
                                .height(52.dp),
                            containerColor = NotelPrimary
                        ) {
                            if (isLoading) {
                                CircularProgressIndicator(color = Color.White, modifier = Modifier.size(22.dp), strokeWidth = 2.dp)
                            } else {
                                Text(
                                    text = when {
                                        isForgotPasswordMode -> "Send Reset Link"
                                        isRegisterMode -> "Create Account"
                                        else -> "Log In"
                                    },
                                    color = Color.White,
                                    fontWeight = FontWeight.Bold,
                                    fontSize = 16.sp
                                )
                            }
                        }

                        if (!isRegisterMode && !isForgotPasswordMode) {
                            Spacer(Modifier.height(12.dp))
                            TextButton(onClick = { isForgotPasswordMode = true; viewModel.setError(null) }) {
                                Text("Forgot Password?", color = NotelPrimary, fontSize = 12.sp, fontWeight = FontWeight.Bold)
                            }
                        } else if (isForgotPasswordMode) {
                            Spacer(Modifier.height(12.dp))
                            TextButton(onClick = { isForgotPasswordMode = false; viewModel.setError(null) }) {
                                Text("Back to Log in", color = NotelTextSecondary, fontSize = 12.sp)
                            }
                        }

                        Spacer(Modifier.height(20.dp))

                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier.fillMaxWidth()
                        ) {
                            HorizontalDivider(modifier = Modifier.weight(1f), color = NotelTextSecondary.copy(alpha = 0.2f))
                            Text(
                                text = "  or  ",
                                fontSize = 12.sp,
                                color = NotelTextSecondary
                            )
                            HorizontalDivider(modifier = Modifier.weight(1f), color = NotelTextSecondary.copy(alpha = 0.2f))
                        }

                        Spacer(Modifier.height(20.dp))

                        // GOOGLE AUTH BUTTON (ON BOTTOM)
                        Button(
                            onClick = {
                                try {
                                    val intent = android.accounts.AccountManager.newChooseAccountIntent(
                                        null,
                                        null,
                                        arrayOf("com.google"),
                                        false,
                                        null,
                                        null,
                                        null,
                                        null
                                    )
                                    googleAccountLauncher.launch(intent)
                                } catch (e: Exception) {
                                    viewModel.loginWithGoogleAccount("tysonscadden@gmail.com")
                                }
                            },
                            colors = ButtonDefaults.buttonColors(containerColor = NotelSurfaceHigh),
                            shape = RoundedCornerShape(16.dp),
                            modifier = Modifier
                                .fillMaxWidth()
                                .height(50.dp)
                        ) {
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.Center
                            ) {
                                Image(
                                    painter = painterResource(id = R.drawable.ic_google_logo),
                                    contentDescription = "Google Logo",
                                    modifier = Modifier.size(20.dp)
                                )
                                Spacer(Modifier.width(12.dp))
                                Text(
                                    text = if (isRegisterMode) "Continue with Google" else "Log in with Google",
                                    fontSize = 15.sp,
                                    fontWeight = FontWeight.SemiBold,
                                    color = NotelTextPrimary
                                )
                            }
                        }
                    }
                }

                Spacer(Modifier.height(16.dp))

                // SMALL TERMS & PRIVACY TEXT OUTSIDE MAIN CARD
                FlowRow(
                    horizontalArrangement = Arrangement.Center,
                    verticalArrangement = Arrangement.Center,
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Text(
                        text = "By signing up you agree to our ",
                        fontSize = 9.5.sp,
                        color = NotelTextSecondary,
                        textAlign = TextAlign.Center
                    )
                    Text(
                        text = "Terms of Use",
                        fontSize = 9.5.sp,
                        fontWeight = FontWeight.Bold,
                        color = NotelPrimary,
                        modifier = Modifier.clickable {
                            val intent = android.content.Intent(android.content.Intent.ACTION_VIEW, android.net.Uri.parse("https://api.jottracker.com/terms.html"))
                            context.startActivity(intent)
                        }
                    )
                    Text(
                        text = " and ",
                        fontSize = 9.5.sp,
                        color = NotelTextSecondary
                    )
                    Text(
                        text = "Privacy Policy",
                        fontSize = 9.5.sp,
                        fontWeight = FontWeight.Bold,
                        color = NotelPrimary,
                        modifier = Modifier.clickable {
                            val intent = android.content.Intent(android.content.Intent.ACTION_VIEW, android.net.Uri.parse("https://api.jottracker.com/privacy.html"))
                            context.startActivity(intent)
                        }
                    )
                    Text(
                        text = ".",
                        fontSize = 9.5.sp,
                        color = NotelTextSecondary
                    )
                }

                Spacer(Modifier.height(24.dp))
            }
        }
    }
}
