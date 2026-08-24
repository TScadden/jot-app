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
import com.notel.notel.data.remote.GoogleAuthRequest
import com.notel.notel.data.remote.ForgotPasswordRequest
import com.notel.notel.data.remote.TabsApi
import com.notel.notel.data.sync.SyncManager
import com.notel.notel.ui.theme.*
import com.google.android.gms.auth.api.signin.GoogleSignIn
import com.google.android.gms.auth.api.signin.GoogleSignInOptions
import com.google.android.gms.auth.api.signin.GoogleSignInAccount
import com.google.android.gms.common.api.ApiException
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
                    preferences.setUserEmail(email)
                    preferences.setOnboardingComplete(true)
                    preferences.setCupTheorySeen(true)
                    preferences.setSettingsTutorialSeen(true)
                    
                    body.isUnlimited?.let { preferences.setIsUnlimited(it) }
                    body.isAdmin?.let { preferences.setIsAdmin(it) }
                    body.nickname?.let { preferences.setUserNickname(it) }
                    body.tag?.let { preferences.setUserTag(it) }
                    
                    syncManager.pullAllData()
                    
                    onboardingCompleteByServer = true
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

    fun loginWithGoogleAccount(idToken: String, isRegisterMode: Boolean) {
        viewModelScope.launch {
            isLoading = true
            errorMsg = null
            try {
                val response = tabsApi.googleLogin(GoogleAuthRequest(idToken, isRegisterMode))
                val body = response.body()
                
                if (response.isSuccessful && body != null && body.token?.isNotBlank() == true) {
                    val email = body.email ?: ""
                    preferences.setAuthToken(body.token!!)
                    preferences.setLoggedIn(true)
                    preferences.setUserEmail(email)
                    preferences.setGoogleAccountConnected(true)
                    preferences.setGoogleAccountEmail(email)
                    preferences.setOnboardingComplete(true)
                    preferences.setCupTheorySeen(true)
                    preferences.setSettingsTutorialSeen(true)

                    body.isUnlimited?.let { preferences.setIsUnlimited(it) }
                    body.isAdmin?.let { preferences.setIsAdmin(it) }
                    body.nickname?.let { preferences.setUserNickname(it) }
                    body.tag?.let { preferences.setUserTag(it) }

                    syncManager.pullAllData()

                    onboardingCompleteByServer = true
                    isLoggedIn = true
                } else {
                    val errorStr = response.errorBody()?.string() ?: ""
                    val errorMessage = try {
                        if (errorStr.contains("\"error\":")) {
                           errorStr.substringAfter("\"error\":\"").substringBefore("\"")
                        } else null
                    } catch (e: Exception) { null }
                    
                    errorMsg = errorMessage ?: (body?.error ?: "Google login failed")
                }
            } catch (e: Exception) {
                errorMsg = e.message ?: "Google login failed"
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
                    preferences.setUserEmail(email)
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

    val googleSignInOptions = remember {
        GoogleSignInOptions.Builder(GoogleSignInOptions.DEFAULT_SIGN_IN)
            .requestIdToken(context.getString(R.string.google_web_client_id))
            .requestEmail()
            .build()
    }
    val googleSignInClient = remember {
        GoogleSignIn.getClient(context, googleSignInOptions)
    }

    val googleAccountLauncher = androidx.activity.compose.rememberLauncherForActivityResult(
        contract = androidx.activity.result.contract.ActivityResultContracts.StartActivityForResult()
    ) { result ->
        if (result.resultCode == android.app.Activity.RESULT_OK && result.data != null) {
            val task = GoogleSignIn.getSignedInAccountFromIntent(result.data)
            try {
                val account: GoogleSignInAccount = task.getResult(ApiException::class.java)
                val idToken = account.idToken
                if (!idToken.isNullOrBlank()) {
                    viewModel.loginWithGoogleAccount(idToken, isRegisterMode)
                } else {
                    viewModel.setError("Could not get Google ID token")
                }
            } catch (e: ApiException) {
                viewModel.setError("Google Sign In failed: ${e.message} (status code: ${e.statusCode})")
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
            // TOP LOGO HEADER - PINNED TO TOP
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 20.dp, vertical = 16.dp)
                    .align(Alignment.TopCenter)
            ) {
                TopLogoHeader(
                    onBack = onBack,
                    modifier = Modifier.padding(top = 8.dp)
                )
            }

            // CARD + TERMS - PERFECTLY CENTERED VERTICALLY AND HORIZONTALLY IN SCREEN
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .align(Alignment.Center)
                    .verticalScroll(rememberScrollState())
                    .padding(horizontal = 20.dp, vertical = 16.dp),
                horizontalAlignment = Alignment.CenterHorizontally
            ) {
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
                                cursorColor = NotelPrimary,
                                focusedTextColor = NotelTextPrimary,
                                unfocusedTextColor = NotelTextPrimary
                            ),
                            shape = RoundedCornerShape(14.dp),
                            modifier = Modifier.fillMaxWidth()
                        )

                        Spacer(Modifier.height(14.dp))

                        if (!isForgotPasswordMode) {
                            // PASSWORD TEXT FIELD
                            OutlinedTextField(
                                value = password,
                                onValueChange = { password = it; viewModel.setError(null) },
                                label = { Text("Password") },
                                leadingIcon = { Icon(Icons.Default.Lock, contentDescription = null, tint = NotelTextSecondary) },
                                trailingIcon = {
                                    IconButton(onClick = { passwordVisible = !passwordVisible }) {
                                        Icon(
                                            imageVector = if (passwordVisible) Icons.Default.Visibility else Icons.Default.VisibilityOff,
                                            contentDescription = if (passwordVisible) "Hide password" else "Show password",
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
                                    cursorColor = NotelPrimary,
                                    focusedTextColor = NotelTextPrimary,
                                    unfocusedTextColor = NotelTextPrimary
                                ),
                                shape = RoundedCornerShape(14.dp),
                                modifier = Modifier.fillMaxWidth()
                            )

                            Spacer(Modifier.height(8.dp))
                        }

                        // ERROR / SUCCESS MESSAGES
                        AnimatedVisibility(visible = errorMsg != null || successMsg != null) {
                            Text(
                                text = errorMsg ?: successMsg ?: "",
                                color = if (errorMsg != null) MaterialTheme.colorScheme.error else NotelPrimary,
                                fontSize = 13.sp,
                                textAlign = TextAlign.Center,
                                modifier = Modifier.padding(vertical = 4.dp)
                            )
                        }

                        // FORGOT PASSWORD LINK (Shown only in Login mode)
                        if (!isRegisterMode && !isForgotPasswordMode) {
                            Box(
                                modifier = Modifier.fillMaxWidth(),
                                contentAlignment = Alignment.CenterEnd
                            ) {
                                TextButton(onClick = { isForgotPasswordMode = true }) {
                                    Text("Forgot Password?", color = NotelPrimary, fontSize = 13.sp)
                                }
                            }
                        } else {
                            Spacer(Modifier.height(8.dp))
                        }

                        // MAIN ACTION BUTTON (Log In, Sign Up, or Reset)
                        Button(
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
                            colors = ButtonDefaults.buttonColors(containerColor = NotelPrimary),
                            shape = RoundedCornerShape(16.dp),
                            modifier = Modifier
                                .fillMaxWidth()
                                .height(50.dp)
                        ) {
                            if (isLoading) {
                                CircularProgressIndicator(modifier = Modifier.size(24.dp), color = NotelBackground)
                            } else {
                                Text(
                                    text = when {
                                        isForgotPasswordMode -> "Send Reset Link"
                                        isRegisterMode -> "Sign Up"
                                        else -> "Log In"
                                    },
                                    fontSize = 16.sp,
                                    fontWeight = FontWeight.Bold,
                                    color = NotelBackground
                                )
                            }
                        }

                        Spacer(Modifier.height(12.dp))

                        // TOGGLE BETWEEN LOGIN AND REGISTER MODES
                        TextButton(
                            onClick = {
                                if (isForgotPasswordMode) {
                                    isForgotPasswordMode = false
                                } else {
                                    isRegisterMode = !isRegisterMode
                                }
                                viewModel.setError(null)
                            }
                        ) {
                            Text(
                                text = when {
                                    isForgotPasswordMode -> "Back to Log In"
                                    isRegisterMode -> "Already have an account? Log In"
                                    else -> "Don't have an account? Sign Up"
                                },
                                color = NotelTextSecondary,
                                fontSize = 13.sp
                            )
                        }

                        Spacer(Modifier.height(16.dp))

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

                        Spacer(Modifier.height(16.dp))

                        // GOOGLE AUTH BUTTON (ON BOTTOM)
                        Button(
                            onClick = {
                                try {
                                    googleSignInClient.signOut().addOnCompleteListener {
                                        val signInIntent = googleSignInClient.signInIntent
                                        googleAccountLauncher.launch(signInIntent)
                                    }
                                } catch (e: Exception) {
                                    viewModel.setError("Could not launch Google Sign In: ${e.message}")
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

                Spacer(Modifier.height(10.dp))

                // SMALL TERMS & PRIVACY TEXT DIRECTLY BELOW CARD
                FlowRow(
                    horizontalArrangement = Arrangement.Center,
                    verticalArrangement = Arrangement.Center,
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Text(
                        text = "By signing up you agree to our ",
                        fontSize = 8.5.sp,
                        color = NotelTextSecondary,
                        textAlign = TextAlign.Center
                    )
                    Text(
                        text = "Terms of Use",
                        fontSize = 8.5.sp,
                        fontWeight = FontWeight.Bold,
                        color = NotelPrimary,
                        modifier = Modifier.clickable {
                            val intent = android.content.Intent(android.content.Intent.ACTION_VIEW, android.net.Uri.parse("https://api.jottracker.com/terms.html"))
                            context.startActivity(intent)
                        }
                    )
                    Text(
                        text = " and ",
                        fontSize = 8.5.sp,
                        color = NotelTextSecondary
                    )
                    Text(
                        text = "Privacy Policy",
                        fontSize = 8.5.sp,
                        fontWeight = FontWeight.Bold,
                        color = NotelPrimary,
                        modifier = Modifier.clickable {
                            val intent = android.content.Intent(android.content.Intent.ACTION_VIEW, android.net.Uri.parse("https://api.jottracker.com/privacy.html"))
                            context.startActivity(intent)
                        }
                    )
                    Text(
                        text = ".",
                        fontSize = 8.5.sp,
                        color = NotelTextSecondary
                    )
                }
            }
        }
    }
}
