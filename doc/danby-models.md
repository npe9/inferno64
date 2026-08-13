# Danby model catalog and interaction design

This is the implementation catalog for models inspired by J. M. A. Danby's
*Computer Modeling: From Sports to Spaceflight, from Order to Chaos*.  The
publisher describes more than fifty companion projects, but their manifest and
source are not in this repository.  Accordingly, this document distinguishes:

- **Built**: implemented in Inferno now.
- **Verified family**: a subject explicitly named in public descriptions of
  the book.
- **Candidate**: a standard model proposed to represent a verified family.  It
  must not be described as a particular Danby project until checked against the
  book or companion CD.

The objective is not a gallery of passive plots.  Every model should make its
state visible and let the user change initial conditions and parameters on the
object being modeled.

## Common interaction language

All model applications should use the same gestures:

| Gesture | Meaning |
| --- | --- |
| Button 1 click or drag | Move a body, seed a population/field, or set an initial condition |
| Button 2 drag | Set a vector: velocity, force, wind, flow, or coupling |
| Button 3 | Open a contextual parameter menu for the object under the pointer |
| Shift + button 1 | Add a second experiment without clearing the first |
| Space | Pause/resume |
| `.` | Advance exactly one integration step |
| `r` | Reset the current experiment |
| `c` | Clear trails while preserving state |
| `+` / `-` | Change simulated time per display frame, not the integrator tolerance |
| `v` | Cycle physical view, time plot, phase portrait, and conserved quantities |
| `p` | Toggle parameter handles and numerical values |

Changing a parameter should leave a faint “ghost” of the previous run so the
effect is immediately comparable.  A reset should be deterministic.  Random
models should display and preserve their seed.

The status strip should always show simulated time, step size, solver, speed,
and any important invariant or error estimate.  Numerical speed and numerical
accuracy must be separate controls.

## Built models

| Model | State and equation | Primary picture | Direct manipulation | Additional views |
| --- | --- | --- | --- | --- |
| Logistic population | population `N`; bounded growth | Population area filling toward a carrying-capacity line | Drag the initial population vertically; drag the capacity line; horizontal rate handle | `N(t)`, per-capita growth, parameter bifurcation sweep |
| Predator–prey ecology | prey and predator populations; Lotka–Volterra | Two living populations in a bounded habitat, with density represented by count and tint | Seed either species; drag birth, predation, and mortality handles | Paired time series and predator-versus-prey phase orbit |
| SIR epidemic | susceptible, infected, recovered fractions | A population strip whose colors flow from S to I to R | Paint an infected cluster; drag contact radius/rate and recovery-time handles | S/I/R curves, effective reproduction number, peak marker |
| Tennis flight | ball position and velocity with gravity and drag | Court side view with net, ball, velocity arrow, and trajectory | Drag ball to serve position; button-2 drag launches it; drag wind vector | Height/range, speed, energy loss, landing/error markers |
| Orbital flight | planar position and velocity in inverse-square gravity | Body-centered orbital view with osculating orbit and velocity arrow | Drag spacecraft; button-2 drag sets velocity; drag central mass/radius handles | Radius/time, energy/angular momentum error, rotating frame |
| Lorenz chaos | three coupled state variables | Rotatable 3-D attractor with two nearby trajectories | Drag initial point; drag `rho`, `sigma`, `beta` handles; seed a neighboring trajectory | XY/XZ/YZ projections, separation versus time, Poincaré section |
| Heat diffusion | scalar field | Continuous false-color temperature field with contours | Paint heat/cold; drag diffusivity; draw insulated or fixed-temperature boundaries | Cross section, total heat, flux arrows |
| Damped wave | displacement and previous-time field | Height/lighting surface or signed color field | Pluck the surface; draw reflecting/absorbing obstacles; drag damping and wave-speed handles | Cross section, energy components, normal modes |
| Gray–Scott reaction | two concentration fields | Continuous reagent color mixture and contours | Paint either reagent; drag feed and kill handles over a parameter map | A/B time trace, `(feed,kill)` pattern atlas |

Each ODE model is a standalone program under `temple` (for example,
`temple/ecology` and `temple/arms`).  Each program owns its equations and
domain view, uses `Numerics` for integration, and may use `Liveplot` for
live axes, series, phase paths, and controls.  There is no model catalog or
compatibility executable.
The field models are in `temple/pdelab`.

## Verified subject families and proposed model set

### Population growth and ecology

| Candidate | Graphic representation | Direct manipulation |
| --- | --- | --- |
| Exponential and logistic growth **(solver built)** | Population silhouettes plus time curve and capacity line | Drag initial population, growth rate, and capacity |
| Harvested population **(solver built)** | Stock and harvest flow, with sustainable threshold | Drag harvest-rate valve; schedule harvest pulses on timeline |
| Competing species **(solver built)** | Two colored territories and competition phase plane | Paint starting territories; drag inter-species pressure arrows |
| Predator–prey with limits **(solver built)** | Habitat animation plus phase orbit | Seed species and edit food capacity or predation radius |
| Food chain **(solver built)** | Node-link trophic web with animated energy flow | Drag population nodes and link-strength handles |
| Migration between patches **(solver built)** | Map of habitat patches with flow arrows | Drag populations between patches; resize corridors |

### Sickness and health

| Candidate | Graphic representation | Direct manipulation |
| --- | --- | --- |
| SIR/SIRS epidemic **(solver built)** | Population field, compartment flows, and curves | Paint infection; drag contact/recovery/immunity controls |
| Vaccination threshold **(solver built)** | Susceptible field with protected regions | Paint vaccination coverage; drag rollout schedule |
| Competing strains **(solver built)** | Two infection colors and shared susceptible pool | Seed either strain; edit cross-immunity link |
| Drug concentration **(solver built)** | Body compartments with concentration traces | Drag dose markers on a timeline; change absorption/elimination |

### Competition and economics

| Candidate | Graphic representation | Direct manipulation |
| --- | --- | --- |
| Price adjustment **(solver built)** | Supply/demand curves and moving equilibrium | Drag either curve or external shock; release to evolve |
| Coupled firms **(solver built)** | Market-share bars and phase portrait | Set initial shares; drag response/cost parameters |
| Boom and bust **(solver built)** | Stocks-and-flows diagram plus time series | Drag investment/consumption valves; inject a shock |
| Arms race **(solver built)** | Two coupled stock gauges | Drag either spending target or coupling arrow |

### Sports

| Candidate | Graphic representation | Direct manipulation |
| --- | --- | --- |
| Vacuum projectile | Field/court view with analytic and numerical trails | Drag launch point and velocity vector |
| Tennis serve | Court and net, drag/lift/wind overlays | Drag serve and spin vectors; move aim point |
| Baseball or golf with spin | 3-D field with Magnus-force and wind arrows | Drag launch/spin/wind; move target |
| Basketball shot | Court view with rim collision envelope | Drag release and velocity; resize release uncertainty cone |
| Skiing/cycling | Course profile with force budget | Draw terrain; drag posture/drag and power controls |
| Running race | Track with runner markers and energy stores | Drag pacing curve directly on distance/time graph |

### Travel and recreation

| Candidate | Graphic representation | Direct manipulation |
| --- | --- | --- |
| Automobile acceleration | Road, speedometer, engine/drag force bars | Drag throttle/brake and road grade |
| Braking distance | Road with reaction and braking segments | Drag initial speed, reaction marker, and friction |
| Boat/aircraft in current | Map with heading, air/water velocity vectors | Drag destination, heading, wind/current vector |
| Pursuit and interception | Moving agents with velocity cones | Drag pursuer/target and their speed vectors |

### Space travel and astronomy

| Candidate | Graphic representation | Direct manipulation |
| --- | --- | --- |
| Circular/elliptic orbit | Orbital view and osculating elements | Drag spacecraft and velocity vector |
| Escape and capture | Energy-colored trajectory and zero-velocity boundary | Drag launch speed/direction and central mass |
| Hohmann transfer | Two orbit rings with burn handles | Drag target orbit; drag impulse vectors at burn points |
| Restricted three-body problem | Rotating frame, primaries, Lagrange points, Jacobi contours | Drag test particle and velocity; move mass-ratio control |
| Comet or flyby | Wide logarithmic view and close encounter inset | Drag asymptotic approach vector and planet position |
| N-body system | Bodies with barycenter and conserved-quantity display | Drag bodies/velocities; add or remove a body contextually |

### Pendulums and springs

| Candidate | Graphic representation | Direct manipulation |
| --- | --- | --- |
| Simple pendulum | Physical pendulum plus phase cylinder | Grab and release bob; drag length and damping |
| Driven pendulum | Pendulum plus moving drive attachment | Drag drive amplitude/frequency handles; strobe at drive phase |
| Double pendulum | Linked arms with nearby ghost trajectory | Grab either bob; separate paired initial states |
| Coupled pendulums | Pendulum row and normal-mode spectrum | Pull any bob; drag couplings between neighbors |
| Duffing oscillator | Mass in double-well potential | Drag mass, drive, damping, and well-depth controls |
| Spring lattice | Deformable mesh and mode heat map | Pull/pin nodes; create/remove springs with button 2 |

### Chemical and other reacting systems

| Candidate | Graphic representation | Direct manipulation |
| --- | --- | --- |
| Reversible reaction | Molecular counts and reaction-flow arrows | Drag initial concentrations and forward/reverse rates |
| Autocatalytic oscillator | Reaction vessel color plus concentration orbit | Add reagent by painting/pouring; drag feed rate |
| Competing reactions | Reaction network and animated flux widths | Drag rate constants on links and initial stocks in nodes |
| Reaction–diffusion | Spatial reagent field | Paint reagents; draw barriers; explore parameter plane |
| Thermal runaway | Vessel temperature/concentration with danger boundary | Drag cooling and feed valves; place sensor thresholds |

### Chaotic systems

| Candidate | Graphic representation | Direct manipulation |
| --- | --- | --- |
| Logistic map | Cobweb plot linked to bifurcation diagram | Drag `r` on bifurcation plot and initial point on axis |
| Lorenz system | 3-D attractor and paired trajectories | Drag initial point and equation parameters |
| Driven pendulum chaos | Physical view, phase plot, and Poincaré section | Grab bob; drag drive amplitude/frequency |
| Duffing chaos | Potential landscape and stroboscopic section | Drag state in phase plane and drive handles |
| Three-body sensitivity | Paired orbital worlds with separation meter | Perturb one body directly by a visible small vector |

## Graphics architecture

Each model should expose a small model-independent scene description:

1. **World layer** — bodies, scalar fields, compartments, or graph nodes.
2. **State layer** — trails, densities, vectors, fluxes, and uncertainty.
3. **Analysis layer** — time plots, phase portraits, invariants, sections.
4. **Handle layer** — draggable initial conditions and parameters.
5. **Annotation layer** — units, current values, solver state, warnings.

The same state snapshot should feed every view, so switching from the physical
picture to a phase portrait never restarts the model.  Handles should carry a
stable identifier and edit a named model parameter; they must not contain
model-specific behavior in the renderer.

For Inferno, applications should render to one retained backing image and flush
once per frame.  Dense fields should use `writepixels`; geometry should be
redrawn only inside its dirty rectangle.  Simulation time must advance on a
timer independently of pointer traffic.

## Implementation order

1. Add universal pause, single-step, view cycling, parameter handles, and ghost
   comparisons to the existing six ODE models.
2. Upgrade tennis and orbit from passive trails to draggable position/velocity
   experiments with physical scenery and invariant/error overlays.
3. Add pendulum, driven pendulum, and double pendulum; these reuse the same
   point/vector handles and phase views.
4. Add logistic-map and Poincaré views to complete the order-to-chaos path.
5. Add three-body, transfer-orbit, and pursuit models.
6. Add economy/competition and richer epidemiology using reusable compartment
   and flow widgets.
7. Add reaction networks, connecting their well-mixed ODE models to the spatial
   PDE laboratory.
8. Audit names, equations, default parameters, and order against the physical
   book or companion CD when either becomes available.
