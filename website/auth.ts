/* ==========================================================================
   Tabs Authentication Logic (Sign In & Sign Up)
   ========================================================================== */

interface AuthResponse {
    token: string;
    refreshToken?: string;
    userId: string;
    email: string;
    nickname?: string;
    tag?: string;
    onboardingComplete?: boolean;
    error?: string;
}

// Token session helper
export const getApiBaseUrl = (): string => {
    const hostname = window.location.hostname;
    if (hostname === 'localhost' || hostname === '127.0.0.1') {
        return 'http://localhost:3000';
    }
    return 'https://api.jottracker.com';
};

export const refreshSessionIfNeeded = async (): Promise<string | null> => {
    const token = localStorage.getItem('token');
    const refreshToken = localStorage.getItem('refreshToken');

    if (!token && !refreshToken) return null;

    // Test token with quick ping
    try {
        const res = await fetch(`${getApiBaseUrl()}/api/sync/pull`, {
            headers: { 'Authorization': `Bearer ${token}` }
        });

        if (res.ok) return token;

        if (res.status === 401 && refreshToken) {
            // Attempt refresh token exchange
            const refreshRes = await fetch(`${getApiBaseUrl()}/api/auth/refresh`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ refreshToken })
            });

            if (refreshRes.ok) {
                const data = await refreshRes.json();
                localStorage.setItem('token', data.token);
                if (data.refreshToken) localStorage.setItem('refreshToken', data.refreshToken);
                return data.token;
            }
        }
    } catch (e) {
        // Network error, return current token
        return token;
    }

    // Token invalid and refresh failed
    localStorage.removeItem('token');
    localStorage.removeItem('refreshToken');
    return null;
};

document.addEventListener('DOMContentLoaded', async () => {
    // Check session routing
    const activeToken = await refreshSessionIfNeeded();
    if (activeToken) {
        const onboardingComplete = localStorage.getItem('onboardingComplete') === 'true';
        if (!onboardingComplete) {
            window.location.href = '/onboarding.html';
        } else {
            window.location.href = '/dashboard.html';
        }
        return;
    }

    // DOM Elements
    const signinView = document.getElementById('signin-view') as HTMLDivElement | null;
    const signupView = document.getElementById('signup-view') as HTMLDivElement | null;
    const toggleToRegisterBtn = document.getElementById('toggle-to-register') as HTMLButtonElement | null;
    const toggleToSigninBtn = document.getElementById('toggle-to-signin') as HTMLButtonElement | null;

    const supportHeading = document.getElementById('support-heading') as HTMLHeadingElement | null;
    const supportCopy = document.getElementById('support-copy') as HTMLParagraphElement | null;
    const supportBadge = document.getElementById('support-badge') as HTMLSpanElement | null;

    const alertBanner = document.getElementById('auth-alert') as HTMLDivElement | null;

    // Forms
    const signinForm = document.getElementById('signin-form') as HTMLFormElement | null;
    const signupForm = document.getElementById('signup-form') as HTMLFormElement | null;

    // Password Toggles
    const toggleSigninPass = document.getElementById('toggle-signin-password') as HTMLButtonElement | null;
    const toggleSignupPass = document.getElementById('toggle-signup-password') as HTMLButtonElement | null;
    const toggleSignupConfirmPass = document.getElementById('toggle-signup-confirm-password') as HTMLButtonElement | null;

    const signinPassInput = document.getElementById('signin-password') as HTMLInputElement | null;
    const signupPassInput = document.getElementById('signup-password') as HTMLInputElement | null;
    const signupConfirmPassInput = document.getElementById('signup-confirm-password') as HTMLInputElement | null;
    const signupEmailInput = document.getElementById('signup-email') as HTMLInputElement | null;

    // Sign Up Validation Elements
    const reqMinLength = document.getElementById('req-minlength') as HTMLLIElement | null;
    const reqLetterNumber = document.getElementById('req-letternumber') as HTMLLIElement | null;
    const signupEmailError = document.getElementById('signup-email-error') as HTMLDivElement | null;
    const signupConfirmError = document.getElementById('signup-confirm-error') as HTMLDivElement | null;
    const signupTermsError = document.getElementById('signup-terms-error') as HTMLDivElement | null;

    // Mode state
    let isRegisterMode = false;

    // Helper: Determine API Base URL
    const getApiBaseUrl = (): string => {
        const hostname = window.location.hostname;
        if (hostname === 'localhost' || hostname === '127.0.0.1') {
            return 'http://localhost:3000';
        }
        return 'https://api.jottracker.com';
    };

    // Helper: Show Alert
    const showAlert = (message: string, type: 'error' | 'success') => {
        if (!alertBanner) return;
        alertBanner.textContent = message;
        alertBanner.className = `auth-alert-banner ${type}`;
        alertBanner.focus();
    };

    // Helper: Clear Alert
    const clearAlert = () => {
        if (!alertBanner) return;
        alertBanner.style.display = 'none';
        alertBanner.className = 'auth-alert-banner';
    };

    // Toggle Password Visibility
    const setupPasswordToggle = (button: HTMLButtonElement | null, input: HTMLInputElement | null) => {
        if (!button || !input) return;
        button.addEventListener('click', () => {
            const isPassword = input.type === 'password';
            input.type = isPassword ? 'text' : 'password';
            button.textContent = isPassword ? 'Hide' : 'Show';
            button.setAttribute('aria-label', isPassword ? 'Hide password' : 'Show password');
        });
    };

    setupPasswordToggle(toggleSigninPass, signinPassInput);
    setupPasswordToggle(toggleSignupPass, signupPassInput);
    setupPasswordToggle(toggleSignupConfirmPass, signupConfirmPassInput);

    // Switch between Sign In and Create Account
    const switchMode = (toRegister: boolean) => {
        clearAlert();
        isRegisterMode = toRegister;

        if (toRegister) {
            signinView?.classList.add('hidden');
            signupView?.classList.remove('hidden');

            if (supportBadge) supportBadge.textContent = 'Join Tabs';
            if (supportHeading) supportHeading.textContent = 'Understand what affects your body.';
            if (supportCopy) supportCopy.textContent = 'Bring your symptoms, routines, and health context together in one place.';

            signupEmailInput?.focus();
        } else {
            signupView?.classList.add('hidden');
            signinView?.classList.remove('hidden');

            if (supportBadge) supportBadge.textContent = 'Welcome Back';
            if (supportHeading) supportHeading.textContent = 'Welcome back.';
            if (supportCopy) supportCopy.textContent = 'Your logs, patterns, and health context are ready when you are.';

            document.getElementById('signin-email')?.focus();
        }
    };

    toggleToRegisterBtn?.addEventListener('click', () => switchMode(true));
    toggleToSigninBtn?.addEventListener('click', () => switchMode(false));

    // Live Password Requirements Checking
    if (signupPassInput) {
        signupPassInput.addEventListener('input', () => {
            const val = signupPassInput.value;
            const hasMinLength = val.length >= 8;
            const hasLetterAndNumber = /[a-zA-Z]/.test(val) && /[0-9]/.test(val);

            if (reqMinLength) {
                reqMinLength.classList.toggle('valid', hasMinLength);
            }
            if (reqLetterNumber) {
                reqLetterNumber.classList.toggle('valid', hasLetterAndNumber);
            }

            // Also check confirm password match live if typed
            if (signupConfirmPassInput && signupConfirmPassInput.value.length > 0) {
                const isMatch = val === signupConfirmPassInput.value;
                signupConfirmPassInput.classList.toggle('invalid', !isMatch);
                if (signupConfirmError) {
                    signupConfirmError.classList.toggle('visible', !isMatch);
                    signupConfirmError.textContent = isMatch ? '' : 'Passwords do not match.';
                }
            }
        });
    }

    // Confirm Password Live Validation
    if (signupConfirmPassInput) {
        signupConfirmPassInput.addEventListener('input', () => {
            const isMatch = signupConfirmPassInput.value === (signupPassInput?.value || '');
            signupConfirmPassInput.classList.toggle('invalid', !isMatch);
            if (signupConfirmError) {
                signupConfirmError.classList.toggle('visible', !isMatch);
                signupConfirmError.textContent = isMatch ? '' : 'Passwords do not match.';
            }
        });
    }

    // Common Post-Auth Routing Logic
    const handleAuthSuccess = (data: AuthResponse, isNewRegistration: boolean = false) => {
        // Save auth data to localStorage
        localStorage.setItem('token', data.token);
        localStorage.setItem('userId', data.userId);
        localStorage.setItem('email', data.email);
        if (data.refreshToken) localStorage.setItem('refreshToken', data.refreshToken);
        if (data.nickname) localStorage.setItem('nickname', data.nickname);
        if (data.tag) localStorage.setItem('tag', data.tag);

        const onboardingComplete = data.onboardingComplete === true;
        localStorage.setItem('onboardingComplete', onboardingComplete ? 'true' : 'false');

        showAlert('Authentication successful! Redirecting...', 'success');

        setTimeout(() => {
            // "Newly registered users always enter onboarding"
            // "If onboardingComplete is false or absent, route the user into web onboarding. If onboardingComplete is true, route the user to /dashboard."
            if (isNewRegistration || !onboardingComplete) {
                window.location.href = '/onboarding.html';
            } else {
                window.location.href = '/dashboard.html';
            }
        }, 800);
    };

    // Sign In Submission Handler
    signinForm?.addEventListener('submit', async (e: Event) => {
        e.preventDefault();
        clearAlert();

        const emailInput = document.getElementById('signin-email') as HTMLInputElement;
        const passwordInput = document.getElementById('signin-password') as HTMLInputElement;
        const submitBtn = document.getElementById('signin-submit-btn') as HTMLButtonElement;

        const email = emailInput.value.trim();
        const password = passwordInput.value;

        if (!email || !password) {
            showAlert('Please enter both email address and password.', 'error');
            return;
        }

        submitBtn.disabled = true;
        submitBtn.textContent = 'Signing In...';

        try {
            const response = await fetch(`${getApiBaseUrl()}/api/auth/login`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ email, password })
            });

            const data: AuthResponse = await response.json();

            if (response.ok) {
                handleAuthSuccess(data, false);
            } else {
                showAlert(data.error || 'Authentication failed. Please check your credentials.', 'error');
                submitBtn.disabled = false;
                submitBtn.textContent = 'Sign In';
            }
        } catch (err) {
            console.error('Sign In error:', err);
            showAlert('Unable to connect to the authentication server. Please check your network.', 'error');
            submitBtn.disabled = false;
            submitBtn.textContent = 'Sign In';
        }
    });

    // Create Account Submission Handler
    signupForm?.addEventListener('submit', async (e: Event) => {
        e.preventDefault();
        clearAlert();

        if (!signupEmailInput || !signupPassInput || !signupConfirmPassInput) return;

        const submitBtn = document.getElementById('signup-submit-btn') as HTMLButtonElement;
        const termsCheckbox = document.getElementById('accept-terms') as HTMLInputElement;

        const email = signupEmailInput.value.trim();
        const password = signupPassInput.value;
        const confirmPassword = signupConfirmPassInput.value;

        let hasError = false;

        // Reset inline errors
        signupEmailInput.classList.remove('invalid');
        signupPassInput.classList.remove('invalid');
        signupConfirmPassInput.classList.remove('invalid');
        if (signupEmailError) signupEmailError.classList.remove('visible');
        if (signupConfirmError) signupConfirmError.classList.remove('visible');
        if (signupTermsError) signupTermsError.classList.remove('visible');

        // Email validation
        if (!email || !email.includes('@')) {
            signupEmailInput.classList.add('invalid');
            if (signupEmailError) {
                signupEmailError.textContent = 'Please enter a valid email address.';
                signupEmailError.classList.add('visible');
            }
            hasError = true;
        }

        // Password requirements validation
        if (password.length < 8) {
            signupPassInput.classList.add('invalid');
            showAlert('Password must be at least 8 characters long.', 'error');
            hasError = true;
        }

        // Confirm password match
        if (password !== confirmPassword) {
            signupConfirmPassInput.classList.add('invalid');
            if (signupConfirmError) {
                signupConfirmError.textContent = 'Passwords do not match.';
                signupConfirmError.classList.add('visible');
            }
            hasError = true;
        }

        // Terms acceptance
        if (!termsCheckbox.checked) {
            if (signupTermsError) {
                signupTermsError.textContent = 'You must accept the Terms of Service and Privacy Policy to create an account.';
                signupTermsError.classList.add('visible');
            }
            hasError = true;
        }

        if (hasError) return;

        submitBtn.disabled = true;
        submitBtn.textContent = 'Creating Account...';

        try {
            const response = await fetch(`${getApiBaseUrl()}/api/auth/register`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ email, password })
            });

            const data: AuthResponse = await response.json();

            if (response.ok) {
                handleAuthSuccess(data, true);
            } else {
                showAlert(data.error || 'Account registration failed. Please try again.', 'error');
                submitBtn.disabled = false;
                submitBtn.textContent = 'Create Account';
            }
        } catch (err) {
            console.error('Registration error:', err);
            showAlert('Unable to connect to the server. Please check your connection.', 'error');
            submitBtn.disabled = false;
            submitBtn.textContent = 'Create Account';
        }
    });
});
