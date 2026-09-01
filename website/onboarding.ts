import './onboarding.css';
import { authenticatedFetch, clearSession } from './auth';

// Predefined condition options matching common conditions in app
const COMMON_CONDITIONS = [
    'ADHD', 'Anxiety', 'Asthma', 'Chronic Fatigue Syndrome (ME/CFS)',
    'Depression', 'Diabetes (Type 1)', 'Diabetes (Type 2)', 'Eczema / Psoriasis',
    'Fibromyalgia', 'GERD / Acid Reflux', 'Hypertension (High Blood Pressure)',
    'Hypothyroidism', 'IBS (Irritable Bowel Syndrome)', 'Insomnia',
    'Long COVID', 'Migraine', 'POTs (Postural Orthostatic Tachycardia)',
    'Rheumatoid Arthritis'
];

interface ProfileState {
    hasConsented: boolean;
    userContext: string;
    conditions: string[];
    medications: string[];
    onboardingComplete: boolean;
    currentStep: number;
}

const STORAGE_KEY = 'tabs_onboarding_draft';
const API_BASE = window.location.hostname === 'localhost' || window.location.hostname === '127.0.0.1'
    ? 'http://localhost:3000'
    : 'https://api.jottracker.com';

class OnboardingController {
    private state: ProfileState = {
        hasConsented: false,
        userContext: '',
        conditions: [],
        medications: [],
        onboardingComplete: false,
        currentStep: 1
    };

    private token: string | null = null;

    constructor() {
        this.init();
    }

    private async init() {
        this.token = sessionStorage.getItem('token');
        if (!this.token) {
            window.location.href = '/login.html';
            return;
        }

        // Load local draft first
        this.loadLocalDraft();

        // Fetch current user profile to verify token and resume state
        await this.fetchProfile();

        this.bindEvents();
        this.renderStep();
    }

    private loadLocalDraft() {
        const saved = localStorage.getItem(STORAGE_KEY);
        if (saved) {
            try {
                const parsed = JSON.parse(saved);
                this.state = { ...this.state, ...parsed };
            } catch (e) {
                // Ignore corrupt draft
            }
        }
    }

    private saveLocalDraft() {
        localStorage.setItem(STORAGE_KEY, JSON.stringify(this.state));
    }

    private async fetchProfile() {
        try {
            const res = await authenticatedFetch(`${API_BASE}/api/sync/pull`);
            if (res.ok) {
                const data = await res.json();
                const prof = data.profile || {};
                
                if (prof.onboardingComplete) {
                    window.location.href = '/dashboard.html';
                    return;
                }

                // If user has existing profile context or conditions on server, hydrate
                if (prof.userContext) this.state.userContext = prof.userContext;
                if (prof.conditions) {
                    try {
                        this.state.conditions = typeof prof.conditions === 'string' ? JSON.parse(prof.conditions) : prof.conditions;
                    } catch (e) { }
                }
                if (prof.medications) {
                    try {
                        this.state.medications = typeof prof.medications === 'string' ? JSON.parse(prof.medications) : prof.medications;
                    } catch (e) { }
                }

                // Determine step to resume if consent granted
                if (this.state.hasConsented && this.state.currentStep === 1) {
                    this.state.currentStep = 2;
                }
            }
        } catch (err) {
            // Network failure: retain local draft and proceed safely
        }
    }

    private bindEvents() {
        document.getElementById('logoutBtn')?.addEventListener('click', () => {
            clearSession();
            localStorage.removeItem(STORAGE_KEY);
            window.location.href = '/login.html';
        });

        document.getElementById('nextBtn')?.addEventListener('click', () => this.handleNext());
        document.getElementById('prevBtn')?.addEventListener('click', () => this.handlePrev());
        document.getElementById('skipBtn')?.addEventListener('click', () => this.handleNext(true));

        const consentCb = document.getElementById('consentCheckbox') as HTMLInputElement;
        consentCb?.addEventListener('change', () => {
            this.state.hasConsented = consentCb.checked;
            this.saveLocalDraft();
            this.updateNextButtonState();
        });

        const contextTa = document.getElementById('userContextInput') as HTMLTextAreaElement;
        contextTa?.addEventListener('input', () => {
            this.state.userContext = contextTa.value;
            this.updateWordCounter(contextTa.value);
            this.saveLocalDraft();
        });

        // Search inputs
        const condSearch = document.getElementById('conditionSearch') as HTMLInputElement;
        condSearch?.addEventListener('input', () => this.renderConditionsList(condSearch.value));
        condSearch?.addEventListener('keydown', (e) => {
            if (e.key === 'Enter' && condSearch.value.trim()) {
                e.preventDefault();
                this.addCondition(condSearch.value.trim());
                condSearch.value = '';
                this.renderConditionsList();
            }
        });

        const medSearch = document.getElementById('medicationSearch') as HTMLInputElement;
        medSearch?.addEventListener('keydown', (e) => {
            if (e.key === 'Enter' && medSearch.value.trim()) {
                e.preventDefault();
                this.addMedication(medSearch.value.trim());
                medSearch.value = '';
                this.renderMedicationsList();
            }
        });
    }

    private updateNextButtonState() {
        const nextBtn = document.getElementById('nextBtn') as HTMLButtonElement;
        if (this.state.currentStep === 1) {
            nextBtn.disabled = !this.state.hasConsented;
        } else {
            nextBtn.disabled = false;
        }
    }

    private updateWordCounter(text: string) {
        const words = text.trim() ? text.trim().split(/\s+/).filter(Boolean).length : 0;
        const counterEl = document.getElementById('wordCounter');
        const feedbackEl = document.getElementById('contextFeedback');

        if (counterEl) counterEl.textContent = `${words} / 100 words`;
        if (feedbackEl) {
            if (words === 0) feedbackEl.textContent = 'Provide at least 10 words for better AI personalization.';
            else if (words < 10) feedbackEl.textContent = `Keep typing (${words}/10 words min)...`;
            else feedbackEl.textContent = 'Optimal context length reached for AI summaries!';
        }
    }

    private addCondition(cond: string) {
        if (!this.state.conditions.includes(cond)) {
            this.state.conditions.push(cond);
            this.saveLocalDraft();
        }
    }

    private removeCondition(cond: string) {
        this.state.conditions = this.state.conditions.filter(c => c !== cond);
        this.saveLocalDraft();
    }

    private addMedication(med: string) {
        if (!this.state.medications.includes(med)) {
            this.state.medications.push(med);
            this.saveLocalDraft();
        }
    }

    private removeMedication(med: string) {
        this.state.medications = this.state.medications.filter(m => m !== med);
        this.saveLocalDraft();
    }

    private renderConditionsList(query = '') {
        const container = document.getElementById('conditionsList');
        if (!container) return;

        const filtered = COMMON_CONDITIONS.filter(c => c.toLowerCase().includes(query.toLowerCase()));
        
        let html = '';
        // Show selected custom conditions not in predefined list first
        const customSelected = this.state.conditions.filter(c => !COMMON_CONDITIONS.includes(c));
        customSelected.forEach(cond => {
            html += `<span class="tag-chip selected" data-cond="${cond}">${cond} &times;</span>`;
        });

        filtered.forEach(cond => {
            const isSelected = this.state.conditions.includes(cond);
            html += `<span class="tag-chip ${isSelected ? 'selected' : ''}" data-cond="${cond}">${cond}${isSelected ? ' &times;' : ''}</span>`;
        });

        container.innerHTML = html;

        container.querySelectorAll('.tag-chip').forEach(chip => {
            chip.addEventListener('click', () => {
                const cond = chip.getAttribute('data-cond');
                if (!cond) return;
                if (this.state.conditions.includes(cond)) {
                    this.removeCondition(cond);
                } else {
                    this.addCondition(cond);
                }
                this.renderConditionsList(query);
            });
        });
    }

    private renderMedicationsList() {
        const container = document.getElementById('medicationsList');
        if (!container) return;

        if (this.state.medications.length === 0) {
            container.innerHTML = `<span style="color: var(--text-muted); font-size: 0.85rem; font-style: italic;">No medications added yet. Type above and press Enter.</span>`;
            return;
        }

        let html = '';
        this.state.medications.forEach(med => {
            html += `<span class="tag-chip selected" data-med="${med}">${med} &times;</span>`;
        });
        container.innerHTML = html;

        container.querySelectorAll('.tag-chip').forEach(chip => {
            chip.addEventListener('click', () => {
                const med = chip.getAttribute('data-med');
                if (med) {
                    this.removeMedication(med);
                    this.renderMedicationsList();
                }
            });
        });
    }

    private async handleNext(isSkipping = false) {
        this.clearNotice();

        if (this.state.currentStep === 1) {
            if (!this.state.hasConsented) {
                this.showNotice('Explicit consent is required to proceed.');
                return;
            }
            // Save consent state step
            await this.syncStepProfile(false);
        } else if (this.state.currentStep === 2) {
            // Context step save
            await this.syncStepProfile(false);
        } else if (this.state.currentStep === 3) {
            // Conditions / meds step save
            await this.syncStepProfile(false);
        } else if (this.state.currentStep === 5 && !isSkipping) {
            // Final submission -> set onboardingComplete = true
            const success = await this.syncStepProfile(true);
            if (success) {
                this.state.onboardingComplete = true;
                this.saveLocalDraft();
                this.renderSuccessState();
                return;
            } else {
                return; // Failed to sync, stay on step 5
            }
        }

        if (this.state.currentStep < 5) {
            this.state.currentStep++;
            this.saveLocalDraft();
            this.renderStep();
        }
    }

    private handlePrev() {
        if (this.state.currentStep > 1) {
            this.state.currentStep--;
            this.saveLocalDraft();
            this.renderStep();
        }
    }

    private async syncStepProfile(onboardingCompleteState: boolean): Promise<boolean> {
        const nextBtn = document.getElementById('nextBtn') as HTMLButtonElement;
        const originalText = nextBtn.textContent;
        nextBtn.disabled = true;
        nextBtn.textContent = 'Saving...';

        try {
            const bodyPayload = {
                userContext: this.state.userContext,
                conditions: JSON.stringify(this.state.conditions),
                medications: JSON.stringify(this.state.medications),
                onboardingComplete: onboardingCompleteState
            };

            const res = await authenticatedFetch(`${API_BASE}/api/sync/profile`, {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json'
                },
                body: JSON.stringify(bodyPayload)
            });

            if (!res.ok) {
                const errData = await res.json().catch(() => ({}));
                this.showNotice(errData.error || 'Failed to save progress to server. Retrying local draft...');
                return false;
            }

            return true;
        } catch (err) {
            this.showNotice('Network connectivity error. Your progress is saved locally.');
            return false;
        } finally {
            nextBtn.disabled = false;
            nextBtn.textContent = originalText;
        }
    }

    private renderStep() {
        const step = this.state.currentStep;

        // Progress bar
        const fill = document.getElementById('progressFill');
        const counter = document.getElementById('stepCounter');
        const briefTitle = document.getElementById('stepTitleBrief');
        const bar = document.getElementById('progressBar');

        const stepTitles = [
            'Welcome & Consent',
            'Health Context',
            'Conditions & Meds',
            'Biometric Connections',
            'Review & Finish'
        ];

        if (fill) fill.style.width = `${(step / 5) * 100}%`;
        if (counter) counter.textContent = `Step ${step} of 5`;
        if (briefTitle) briefTitle.textContent = stepTitles[step - 1];
        if (bar) bar.setAttribute('aria-valuenow', step.toString());

        // Toggle visibility of step screens
        for (let i = 1; i <= 5; i++) {
            const stepEl = document.getElementById(`step${i}`);
            if (stepEl) {
                if (i === step) stepEl.classList.remove('hidden');
                else stepEl.classList.add('hidden');
            }
        }

        // Nav buttons
        const prevBtn = document.getElementById('prevBtn');
        const skipBtn = document.getElementById('skipBtn');
        const nextBtn = document.getElementById('nextBtn') as HTMLButtonElement;

        if (prevBtn) prevBtn.style.visibility = step === 1 ? 'hidden' : 'visible';

        if (skipBtn) {
            if (step === 3) skipBtn.classList.remove('hidden');
            else skipBtn.classList.add('hidden');
        }

        if (nextBtn) {
            nextBtn.textContent = step === 5 ? 'Complete Setup' : 'Continue';
        }

        // Populate step-specific inputs
        if (step === 1) {
            const consentCb = document.getElementById('consentCheckbox') as HTMLInputElement;
            if (consentCb) consentCb.checked = this.state.hasConsented;
        } else if (step === 2) {
            const contextTa = document.getElementById('userContextInput') as HTMLTextAreaElement;
            if (contextTa) {
                contextTa.value = this.state.userContext;
                this.updateWordCounter(this.state.userContext);
            }
        } else if (step === 3) {
            this.renderConditionsList();
            this.renderMedicationsList();
        } else if (step === 5) {
            this.renderSummary();
        }

        this.updateNextButtonState();
    }

    private renderSummary() {
        const cEl = document.getElementById('summaryConsent');
        const ctxEl = document.getElementById('summaryContext');
        const condEl = document.getElementById('summaryConditions');
        const medEl = document.getElementById('summaryMedications');

        if (cEl) cEl.textContent = this.state.hasConsented ? 'Granted' : 'Pending';
        if (ctxEl) ctxEl.textContent = this.state.userContext.trim() || 'No health context provided.';
        if (condEl) condEl.textContent = this.state.conditions.length > 0 ? this.state.conditions.join(', ') : 'None specified';
        if (medEl) medEl.textContent = this.state.medications.length > 0 ? this.state.medications.join(', ') : 'None specified';
    }

    private renderSuccessState() {
        const step5Content = document.getElementById('step5');
        const footer = document.getElementById('footerBar');
        const successBox = document.getElementById('successBox');

        if (step5Content) {
            step5Content.querySelectorAll('.info-card').forEach(el => {
                if (el !== successBox) el.classList.add('hidden');
            });
        }

        if (successBox) successBox.classList.remove('hidden');
        if (footer) footer.style.display = 'none';

        // Clear local draft upon successful onboarding completion
        localStorage.removeItem(STORAGE_KEY);
    }

    private showNotice(msg: string) {
        const notice = document.getElementById('onboardingNotice');
        if (notice) {
            notice.textContent = msg;
            notice.classList.remove('hidden');
        }
    }

    private clearNotice() {
        const notice = document.getElementById('onboardingNotice');
        if (notice) {
            notice.textContent = '';
            notice.classList.add('hidden');
        }
    }
}

document.addEventListener('DOMContentLoaded', () => {
    new OnboardingController();
});
