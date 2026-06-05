// Simple intersection observer for reveal animations
const observerOptions = {
    threshold: 0.1
};

const observer = new IntersectionObserver((entries) => {
    entries.forEach(entry => {
        if (entry.isIntersecting) {
            entry.target.classList.add('active'); // Matches .reveal.active in CSS
            
            // Trigger stats animation if this is the stats section
            if (entry.target.classList.contains('stats-section')) {
                const realStats = (window as any).realStats;
                animateStats(realStats);
            }
            
            observer.unobserve(entry.target);
        }
    });
}, observerOptions);

const animateStats = (data?: { jots: number, insights: number, accuracy: number }) => {
    const stats = document.querySelectorAll('.stat-number');
    stats.forEach(stat => {
        const type = stat.parentElement?.querySelector('.stat-label')?.textContent?.toLowerCase();
        let target = parseInt(stat.getAttribute('data-target') || '0');
        
        // Override with real data if available
        if (data) {
            if (type?.includes('notes')) target = data.jots;
            if (type?.includes('trends')) target = data.insights;
            if (type?.includes('accuracy')) target = data.accuracy;
        }

        let count = 0;
        const duration = 2000;
        const increment = target / (duration / 16);
        
        const updateCount = () => {
            count += increment;
            if (count < target) {
                stat.textContent = type?.includes('accuracy') ? count.toFixed(1) : Math.floor(count).toLocaleString();
                requestAnimationFrame(updateCount);
            } else {
                stat.textContent = type?.includes('accuracy') ? target.toFixed(1) : target.toLocaleString();
            }
        };
        updateCount();
    });
};

document.addEventListener('DOMContentLoaded', () => {
    // Check authentication status to update navigation links
    const token = localStorage.getItem('token');
    if (token) {
        const loginLinks = document.querySelectorAll('a[href="/login"]');
        loginLinks.forEach(link => {
            link.setAttribute('href', '/dashboard');
            link.textContent = 'Dashboard';
        });
    }

    // Fetch Real Stats from Server
    fetch('/api/public/stats')
        .then(res => res.json())
        .then(data => {
            // Stats will be triggered by observer, but we store the data globally or pass it
            window['realStats'] = data;
        })
        .catch(err => console.error('Failed to fetch real stats:', err));

    // Reveal animations
    const revealElements = document.querySelectorAll('.reveal');
    revealElements.forEach(el => observer.observe(el));

    // AI Demo Logic
    const demoText = document.getElementById('demo-text');
    const demoBtns = document.querySelectorAll('.demo-btn');
    const demoScenarios: { [key: string]: string } = {
        raw: '"Uhh, so today was okay, I guess. My head kind of hurts a bit... maybe like a 4 out of 10. I ate a sandwich at like 12? Oh, and I did some yoga for 20 minutes."',
        ai: 'Headache: 4/10 intensity. \nLunch: Sandwich at 12:00 PM. \nExercise: 20 minutes of Yoga. \nOverall: Stable wellness day.'
    };

    demoBtns.forEach(btn => {
        btn.addEventListener('click', () => {
            if (btn.classList.contains('active')) return;
            demoBtns.forEach(b => b.classList.remove('active'));
            btn.classList.add('active');
            const mode = btn.getAttribute('data-mode') || 'raw';
            if (demoText) {
                demoText.style.opacity = '0';
                setTimeout(() => {
                    demoText.innerText = demoScenarios[mode];
                    demoText.style.opacity = '1';
                }, 300);
            }
        });
    });

    // Smooth scroll for anchor links
    document.querySelectorAll('a[href^="#"]').forEach(anchor => {
        anchor.addEventListener('click', function (this: HTMLAnchorElement, e) {
            e.preventDefault();
            const href = this.getAttribute('href');
            if (!href || href === '#') return;
            
            const target = document.querySelector(href);
            if (target) {
                target.scrollIntoView({
                    behavior: 'smooth'
                });
            }
        });
    });

    // Modal Logic
    const betaModal = document.getElementById('beta-modal');
    const downloadBtns = document.querySelectorAll('.btn-download');
    const closeBtns = document.querySelectorAll('.modal-close, .btn-close-modal');

    downloadBtns.forEach(btn => {
        btn.addEventListener('click', () => {
            betaModal?.classList.add('active');
            document.body.style.overflow = 'hidden'; // Prevent scrolling
        });
    });

    closeBtns.forEach(btn => {
        btn.addEventListener('click', () => {
            betaModal?.classList.remove('active');
            document.body.style.overflow = ''; // Restore scrolling
        });
    });

    // Close modal on background click
    betaModal?.addEventListener('click', (e) => {
        if (e.target === betaModal) {
            betaModal.classList.remove('active');
            document.body.style.overflow = '';
        }
    });

    // Prevent touch scrolling behind modal on mobile (iOS Safari)
    betaModal?.addEventListener('touchmove', (e) => {
        e.preventDefault();
    }, { passive: false });

    // Simple parallax effect for hero glow
    window.addEventListener('mousemove', (e) => {
        const glow = document.querySelector('.hero-bg .glow') as HTMLElement;
        if (glow) {
            const x = e.clientX / window.innerWidth;
            const y = e.clientY / window.innerHeight;
            glow.style.transform = `translate(${x * 50}px, ${y * 50}px)`;
        }
    });

    // Hero Slider Logic
    const sliderImages = document.querySelectorAll('.hero-slider .screenshot');
    const dots = document.querySelectorAll('.dot');
    let currentImageIndex = 0;
    let sliderInterval: number | undefined;

    const showImage = (index: number) => {
        sliderImages[currentImageIndex].classList.remove('active');
        dots[currentImageIndex].classList.remove('active');
        currentImageIndex = index;
        sliderImages[currentImageIndex].classList.add('active');
        dots[currentImageIndex].classList.add('active');
    };

    const startSlider = () => {
        if (sliderInterval) clearInterval(sliderInterval);
        sliderInterval = window.setInterval(() => {
            const nextIndex = (currentImageIndex + 1) % sliderImages.length;
            showImage(nextIndex);
        }, 4000);
    };

    if (sliderImages.length > 0) {
        startSlider();

        // Add click events to dots
        dots.forEach((dot, index) => {
            dot.addEventListener('click', () => {
                if (currentImageIndex !== index) {
                    showImage(index);
                    startSlider(); // Restart the clock
                }
            });
        });
    }

    // Mobile Navigation Toggle
    const mobileToggle = document.getElementById('mobile-toggle');
    const navLinks = document.getElementById('nav-links');
    const navLinkItems = document.querySelectorAll('#nav-links a');
    const navElement = document.querySelector('nav');

    if (mobileToggle && navLinks) {
        mobileToggle.addEventListener('click', () => {
            mobileToggle.classList.toggle('active');
            navLinks.classList.toggle('active');
            navElement?.classList.toggle('menu-active');
            document.body.style.overflow = navLinks.classList.contains('active') ? 'hidden' : '';
        });

        // Close menu when clicking a link
        navLinkItems.forEach(item => {
            item.addEventListener('click', () => {
                mobileToggle.classList.remove('active');
                navLinks.classList.remove('active');
                navElement?.classList.remove('menu-active');
                document.body.style.overflow = '';
            });
        });
    }
});
