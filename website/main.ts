// Tabs website interactions — vanilla TS, no frameworks.
// Behavior: reveal-on-scroll, manual hero slider (no autoplay), mobile drawer,
// beta modal, FAQ accordion, mobile sticky CTA.

const prefersReducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

document.addEventListener('DOMContentLoaded', () => {
    // --- Auth-aware nav: logged-in users go to the dashboard ---
    const token = localStorage.getItem('token');
    if (token) {
        document.querySelectorAll<HTMLAnchorElement>('a[href="/login"]').forEach(link => {
            link.setAttribute('href', '/dashboard');
            link.textContent = 'Dashboard';
        });
    }

    // --- Reveal-on-scroll ---
    const revealObserver = new IntersectionObserver(entries => {
        entries.forEach(entry => {
            if (entry.isIntersecting) {
                entry.target.classList.add('active');
                revealObserver.unobserve(entry.target);
            }
        });
    }, { threshold: 0.1 });
    document.querySelectorAll('.reveal').forEach(el => revealObserver.observe(el));

    // --- Smooth scroll for in-page anchors ---
    document.querySelectorAll<HTMLAnchorElement>('a[href^="#"]').forEach(anchor => {
        anchor.addEventListener('click', e => {
            const href = anchor.getAttribute('href');
            if (!href || href === '#') return;
            const target = document.querySelector(href);
            if (target) {
                e.preventDefault();
                target.scrollIntoView({ behavior: prefersReducedMotion ? 'auto' : 'smooth' });
            }
        });
    });

    // --- Beta modal ---
    const betaModal = document.getElementById('beta-modal');
    const modalCard = betaModal?.querySelector('.modal-card') as HTMLElement | null;
    let lastOpener: HTMLElement | null = null;

    const setModal = (open: boolean, opener?: HTMLElement) => {
        if (!betaModal) return;
        betaModal.classList.toggle('active', open);
        document.body.style.overflow = open ? 'hidden' : '';
        if (open) {
            lastOpener = opener ?? null;
            updateSticky(true);
            (betaModal.querySelector('.modal-close') as HTMLElement | null)?.focus();
        } else {
            updateSticky(true);
            lastOpener?.focus();
        }
    };

    document.querySelectorAll<HTMLElement>('.btn-open-beta').forEach(btn => {
        btn.addEventListener('click', () => setModal(true, btn));
    });
    betaModal?.querySelectorAll('.modal-close').forEach(btn => {
        btn.addEventListener('click', () => setModal(false));
    });
    betaModal?.addEventListener('click', e => {
        if (e.target === betaModal) setModal(false);
    });
    betaModal?.addEventListener('touchmove', e => e.preventDefault(), { passive: false });
    document.addEventListener('keydown', e => {
        if (e.key === 'Escape' && betaModal?.classList.contains('active')) setModal(false);
    });

    // --- Hero slider: manual only (no autoplay). Swipe + dots + arrows. ---
    const slider = document.getElementById('hero-slider');
    const slides = Array.from(slider?.querySelectorAll('.slide') ?? []);
    const dots = Array.from(document.querySelectorAll<HTMLButtonElement>('.slider-dots .dot'));
    let current = 0;

    const showSlide = (index: number) => {
        const next = (index + slides.length) % slides.length;
        slides[current]?.classList.remove('active');
        dots[current]?.classList.remove('active');
        dots[current]?.setAttribute('aria-selected', 'false');
        current = next;
        slides[current]?.classList.add('active');
        dots[current]?.classList.add('active');
        dots[current]?.setAttribute('aria-selected', 'true');
    };

    if (slides.length > 0) {
        dots.forEach((dot, i) => dot.addEventListener('click', () => showSlide(i)));
        document.getElementById('slider-prev')?.addEventListener('click', () => showSlide(current - 1));
        document.getElementById('slider-next')?.addEventListener('click', () => showSlide(current + 1));

        // Touch swipe
        let touchX: number | null = null;
        slider?.addEventListener('touchstart', e => {
            touchX = e.touches[0].clientX;
        }, { passive: true });
        slider?.addEventListener('touchend', e => {
            if (touchX === null) return;
            const dx = e.changedTouches[0].clientX - touchX;
            if (Math.abs(dx) > 40) showSlide(current + (dx < 0 ? 1 : -1));
            touchX = null;
        }, { passive: true });
    }

    // --- Mobile nav drawer ---
    const navToggle = document.getElementById('nav-toggle');
    const navLinks = document.getElementById('nav-links');
    const nav = navToggle?.closest('nav');
    const setDrawer = (open: boolean) => {
        navToggle?.classList.toggle('open', open);
        navLinks?.classList.toggle('open', open);
        nav?.classList.toggle('drawer-open', open);
        navToggle?.setAttribute('aria-expanded', String(open));
        navToggle?.setAttribute('aria-label', open ? 'Close menu' : 'Open menu');
        document.body.style.overflow = open ? 'hidden' : '';
    };
    navToggle?.addEventListener('click', () => {
        setDrawer(!navLinks?.classList.contains('open'));
    });
    navLinks?.querySelectorAll('a').forEach(a => {
        a.addEventListener('click', () => setDrawer(false));
    });
    document.addEventListener('keydown', e => {
        if (e.key === 'Escape' && navLinks?.classList.contains('open')) setDrawer(false);
    });

    // --- FAQ accordion (collapsed everywhere by default) ---
    document.querySelectorAll('.faq-item').forEach(item => {
        const btn = item.querySelector<HTMLButtonElement>('.faq-q');
        btn?.addEventListener('click', () => {
            const isOpen = item.classList.contains('open');
            document.querySelectorAll('.faq-item.open').forEach(other => {
                other.classList.remove('open');
                other.querySelector('.faq-q')?.setAttribute('aria-expanded', 'false');
            });
            item.classList.toggle('open', !isOpen);
            btn.setAttribute('aria-expanded', String(!isOpen));
        });
    });

    // --- Mobile sticky CTA ---
    // Visible only after the hero scrolls out of view; hidden on the final CTA
    // section, while the beta modal is open, and (via CSS) on desktop.
    const sticky = document.getElementById('sticky-cta');
    const heroEl = document.querySelector('.hero, .page-hero');
    const finalCta = document.getElementById('get');
    let pastHero = false;
    let atFinalCta = false;
    let modalOpen = false;

    function updateSticky(fromModal: boolean) {
        if (fromModal) modalOpen = betaModal?.classList.contains('active') ?? false;
        sticky?.classList.toggle('visible', pastHero && !atFinalCta && !modalOpen && window.innerWidth < 900);
    }

    if (sticky && heroEl) {
        new IntersectionObserver(([entry]) => {
            pastHero = !entry.isIntersecting && entry.boundingClientRect.top < 0;
            updateSticky(false);
        }, { threshold: 0 }).observe(heroEl);
    }
    if (sticky && finalCta) {
        new IntersectionObserver(([entry]) => {
            atFinalCta = entry.isIntersecting;
            updateSticky(false);
        }, { threshold: 0.15 }).observe(finalCta);
    }
    window.addEventListener('resize', () => updateSticky(false), { passive: true });

    // --- Subtle hero glow parallax (skip under reduced motion) ---
    if (!prefersReducedMotion) {
        window.addEventListener('mousemove', e => {
            const glow = document.querySelector('.hero-bg .glow') as HTMLElement | null;
            if (glow) {
                const x = e.clientX / window.innerWidth;
                const y = e.clientY / window.innerHeight;
                glow.style.transform = `translate(calc(-50% + ${x * 50}px), ${y * 50}px)`;
            }
        }, { passive: true });
    }
});
