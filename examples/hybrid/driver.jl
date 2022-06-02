include("cli_options.jl")
if !(@isdefined parsed_args)
    (s, parsed_args) = parse_commandline()
end

include("classify_case.jl")
include("utilities.jl")
const FT = parsed_args["FLOAT_TYPE"] == "Float64" ? Float64 : Float32

fps = parsed_args["fps"]
idealized_h2o = parsed_args["idealized_h2o"]
idealized_insolation = parsed_args["idealized_insolation"]
vert_diff = parsed_args["vert_diff"]
hyperdiff = parsed_args["hyperdiff"]
turbconv = parsed_args["turbconv"]
h_elem = parsed_args["h_elem"]
z_elem = Int(parsed_args["z_elem"])
z_max = FT(parsed_args["z_max"])
κ₄ = parsed_args["kappa_4"]
rayleigh_sponge = parsed_args["rayleigh_sponge"]
viscous_sponge = parsed_args["viscous_sponge"]
zd_rayleigh = parsed_args["zd_rayleigh"]
zd_viscous = parsed_args["zd_viscous"]
κ₂_sponge = parsed_args["kappa_2_sponge"]
t_end = FT(time_to_seconds(parsed_args["t_end"]))
dt = FT(time_to_seconds(parsed_args["dt"]))
dt_save_to_sol = time_to_seconds(parsed_args["dt_save_to_sol"])
dt_save_to_disk = time_to_seconds(parsed_args["dt_save_to_disk"])

@assert idealized_insolation in (true, false)
@assert idealized_h2o in (true, false)
@assert vert_diff in (true, false)
@assert hyperdiff in (true, false)
@assert parsed_args["config"] in ("sphere", "column")
@assert rayleigh_sponge in (true, false)
@assert viscous_sponge in (true, false)

include("types.jl")

import TurbulenceConvection
const TC = TurbulenceConvection
include("TurbulenceConvectionUtils.jl")
import .TurbulenceConvectionUtils
TCU = TurbulenceConvectionUtils
namelist = turbconv == "edmf" ? TCU.NameList.default_namelist("Bomex") : nothing

include("parameter_set.jl")
# TODO: unify parsed_args and namelist
params = create_parameter_set(FT, parsed_args, namelist)

moisture_model() = moisture_model(parsed_args)
energy_form() = energy_form(parsed_args)
radiation_model() = radiation_model(parsed_args)
microphysics_model() = microphysics_model(parsed_args)
forcing_type() = forcing_type(parsed_args)
turbconv_model() = turbconv_model(parsed_args, namelist)

diffuse_momentum = vert_diff && !(forcing_type() isa HeldSuarezForcing)

using NVTX
using OrdinaryDiffEq
using PrettyTables
using DiffEqCallbacks
using JLD2
using ClimaCore.DataLayouts
using NCDatasets
using ClimaCore

import Random
Random.seed!(1234)
include(joinpath("..", "RRTMGPInterface.jl"))
import .RRTMGPInterface
RRTMGPI = RRTMGPInterface

!isnothing(radiation_model()) && include("radiation_utilities.jl")

parse_arg(pa, key, default) = isnothing(pa[key]) ? default : pa[key]


upwinding_mode() = Symbol(parse_arg(parsed_args, "upwinding", "third_order"))
@assert upwinding_mode() in (:none, :first_order, :third_order)

jacobi_flags(::TotalEnergy) =
    (; ∂ᶜ𝔼ₜ∂ᶠ𝕄_mode = :no_∂ᶜp∂ᶜK, ∂ᶠ𝕄ₜ∂ᶜρ_mode = :exact)
jacobi_flags(::InternalEnergy) =
    (; ∂ᶜ𝔼ₜ∂ᶠ𝕄_mode = :exact, ∂ᶠ𝕄ₜ∂ᶜρ_mode = :exact)
jacobi_flags(::PotentialTemperature) =
    (; ∂ᶜ𝔼ₜ∂ᶠ𝕄_mode = :exact, ∂ᶠ𝕄ₜ∂ᶜρ_mode = :exact)
jacobian_flags = jacobi_flags(energy_form())
max_newton_iters = 10 # only required by ODE algorithms that use Newton's method
show_progress_bar = isinteractive()
additional_solver_kwargs = () # e.g., abstol and reltol
test_implicit_solver = false # makes solver extremely slow when set to `true`

# TODO: flip order so that NamedTuple() is fallback.
additional_cache(Y, params, dt; use_tempest_mode = false) = merge(
    hyperdiffusion_cache(Y; κ₄ = FT(κ₄), use_tempest_mode),
    rayleigh_sponge ?
    rayleigh_sponge_cache(Y, dt; zd_rayleigh = FT(zd_rayleigh)) :
    NamedTuple(),
    viscous_sponge ?
    viscous_sponge_cache(Y; zd_viscous = FT(zd_viscous), κ₂ = FT(κ₂_sponge)) : NamedTuple(),
    microphysics_cache(Y, microphysics_model()),
    forcing_cache(Y, forcing_type()),
    isnothing(radiation_model()) ? NamedTuple() :
    rrtmgp_model_cache(
        Y,
        params,
        radiation_model();
        idealized_insolation,
        idealized_h2o,
    ),
    vert_diff ?
    vertical_diffusion_boundary_layer_cache(Y; diffuse_momentum) :
    NamedTuple(),
    (;
        tendency_knobs = (;
            hs_forcing = forcing_type() isa HeldSuarezForcing,
            microphy_0M = microphysics_model() isa Microphysics0Moment,
            rad_flux = !isnothing(radiation_model()),
            vert_diff,
            hyperdiff,
            has_turbconv = !isnothing(turbconv_model()),
        )
    ),
    (; Δt = dt),
    (; enable_default_remaining_tendency = isnothing(turbconv_model())),
    !isnothing(turbconv_model()) ?
    (; edmf_cache = TCU.get_edmf_cache(Y, namelist, params)) : NamedTuple(),
)

additional_tendency!(Yₜ, Y, p, t) = begin
    (; rad_flux, vert_diff, hs_forcing) = p.tendency_knobs
    (; microphy_0M, hyperdiff, has_turbconv) = p.tendency_knobs
    hyperdiff && hyperdiffusion_tendency!(Yₜ, Y, p, t)
    rayleigh_sponge && rayleigh_sponge_tendency!(Yₜ, Y, p, t)
    viscous_sponge && viscous_sponge_tendency!(Yₜ, Y, p, t)
    hs_forcing && held_suarez_tendency!(Yₜ, Y, p, t)
    vert_diff && vertical_diffusion_boundary_layer_tendency!(Yₜ, Y, p, t)
    microphy_0M && zero_moment_microphysics_tendency!(Yₜ, Y, p, t)
    rad_flux && rrtmgp_model_tendency!(Yₜ, Y, p, t)
    has_turbconv && TCU.sgs_flux_tendency!(Yₜ, Y, p, t)
end

################################################################################
is_distributed = haskey(ENV, "CLIMACORE_DISTRIBUTED")

using Logging
if is_distributed
    using ClimaComms
    if ENV["CLIMACORE_DISTRIBUTED"] == "MPI"
        using ClimaCommsMPI
        const comms_ctx = ClimaCommsMPI.MPICommsContext()
    else
        error("ENV[\"CLIMACORE_DISTRIBUTED\"] only supports the \"MPI\" option")
    end
    const pid, nprocs = ClimaComms.init(comms_ctx)
    logger_stream = ClimaComms.iamroot(comms_ctx) ? stderr : devnull
    prev_logger = global_logger(ConsoleLogger(logger_stream, Logging.Info))
    @info "Setting up distributed run on $nprocs \
        processor$(nprocs == 1 ? "" : "s")"
else
    const comms_ctx = nothing
    using TerminalLoggers: TerminalLogger
    prev_logger = global_logger(TerminalLogger())
end
atexit() do
    global_logger(prev_logger)
end
using OrdinaryDiffEq
using DiffEqCallbacks
using JLD2

parsed_args["trunc_stack_traces"] && include("truncate_stack_traces.jl")
include("../implicit_solver_debugging_tools.jl")
include("../ordinary_diff_eq_bug_fixes.jl")
include("../common_spaces.jl")

include(joinpath("sphere", "baroclinic_wave_utilities.jl"))

# Variables required for driver.jl (modify as needed)
function get_ode_algorithm(parsed_args)
    ode_algo = parsed_args["ode_algo"]
    ode_algo_dict = Dict(
        "Rosenbrock23" => OrdinaryDiffEq.Rosenbrock23,
        "Euler" => OrdinaryDiffEq.Euler,
    )
    return ode_algo_dict[ode_algo]
end
ode_algorithm = get_ode_algorithm(parsed_args)

additional_callbacks = if !isnothing(radiation_model())
    # TODO: better if-else criteria?
    dt_rad = parsed_args["config"] == "column" ? dt : FT(6 * 60 * 60)
    (
        PeriodicCallback(
            rrtmgp_model_callback!,
            dt_rad; # update RRTMGPModel every dt_rad
            initial_affect = true, # run callback at t = 0
            save_positions = (false, false), # do not save Y before and after callback
        ),
    )
else
    ()
end

import ClimaCore: enable_threading
enable_threading() = parsed_args["enable_threading"]

# TODO: When is_distributed is true, automatically compute the maximum number of
# bytes required to store an element from Y.c or Y.f (or, really, from any Field
# on which gather() or weighted_dss!() will get called). One option is to make a
# non-distributed space, extract the local_geometry type, and find the sizes of
# the output types of center_initial_condition() and face_initial_condition()
# for that local_geometry type. This is rather inefficient, though, so for now
# we will just hardcode the value of 4.
max_field_element_size = 4 # ρ = 1 byte, 𝔼 = 1 byte, uₕ = 2 bytes

center_space, face_space = if parsed_args["config"] == "sphere"
    quad = Spaces.Quadratures.GLL{5}()
    horizontal_mesh = baroclinic_wave_mesh(; params, h_elem = h_elem)
    h_space = make_horizontal_space(horizontal_mesh, quad, comms_ctx)
    z_stretch = Meshes.GeneralizedExponentialStretching(FT(500), FT(5000))
    make_hybrid_spaces(h_space, z_max, z_elem, z_stretch)
elseif parsed_args["config"] == "column" # single column
    Δx = FT(1) # Note: This value shouldn't matter, since we only have 1 column.
    quad = Spaces.Quadratures.GL{1}()
    horizontal_mesh = periodic_rectangle_mesh(;
        x_max = Δx,
        y_max = Δx,
        x_elem = 1,
        y_elem = 1,
    )
    h_space = make_horizontal_space(horizontal_mesh, quad, comms_ctx)
    z_stretch = if parsed_args["z_stretch"]
        Meshes.GeneralizedExponentialStretching(FT(100), FT(10000))
    else
        Meshes.Uniform()
    end
    make_hybrid_spaces(h_space, z_max, z_elem, z_stretch)
end

models = (;
    moisture_model = moisture_model(),
    energy_form = energy_form(),
    turbconv_model = turbconv_model(),
)

if haskey(ENV, "RESTART_FILE")
    restart_file_name = ENV["RESTART_FILE"]
    if is_distributed
        restart_file_name =
            split(restart_file_name, ".jld2")[1] * "_pid$pid.jld2"
    end
    restart_data = jldopen(restart_file_name)
    t_start = restart_data["t"]
    Y = restart_data["Y"]
    close(restart_data)
    ᶜlocal_geometry = Fields.local_geometry_field(Y.c)
    ᶠlocal_geometry = Fields.local_geometry_field(Y.f)
    # TODO:   quad, horizontal_mesh, z_stretch,
    #         z_max, z_elem should be taken from Y.
    #         when restarting
else
    t_start = FT(0)
    ᶜlocal_geometry = Fields.local_geometry_field(center_space)
    ᶠlocal_geometry = Fields.local_geometry_field(face_space)

    center_initial_condition = if is_baro_wave(parsed_args)
        center_initial_condition_baroclinic_wave
    elseif parsed_args["config"] == "sphere"
        center_initial_condition_sphere
    elseif parsed_args["config"] == "column"
        center_initial_condition_column
    end

    Y = init_state(
        center_initial_condition,
        face_initial_condition,
        center_space,
        face_space,
        params,
        models,
    )
end

p = get_cache(Y, params, upwinding_mode(), dt)
if parsed_args["turbconv"] == "edmf"
    TCU.init_tc!(Y, p, params, namelist)
end

# Print tendencies:
for key in keys(p.tendency_knobs)
    @info "`$(key)`:$(getproperty(p.tendency_knobs, key))"
end

if ode_algorithm <: Union{
    OrdinaryDiffEq.OrdinaryDiffEqImplicitAlgorithm,
    OrdinaryDiffEq.OrdinaryDiffEqAdaptiveImplicitAlgorithm,
}
    use_transform = !(ode_algorithm in (Rosenbrock23, Rosenbrock32))
    W = SchurComplementW(Y, use_transform, jacobian_flags, test_implicit_solver)
    jac_kwargs =
        use_transform ? (; jac_prototype = W, Wfact_t = Wfact!) :
        (; jac_prototype = W, Wfact = Wfact!)

    alg_kwargs = (; linsolve = linsolve!)
    if ode_algorithm <: Union{
        OrdinaryDiffEq.OrdinaryDiffEqNewtonAlgorithm,
        OrdinaryDiffEq.OrdinaryDiffEqNewtonAdaptiveAlgorithm,
    }
        alg_kwargs =
            (; alg_kwargs..., nlsolve = NLNewton(; max_iter = max_newton_iters))
    end
else
    jac_kwargs = alg_kwargs = ()
end

job_id = if isnothing(parsed_args["job_id"])
    job_id_from_parsed_args(s, parsed_args)
else
    parsed_args["job_id"]
end
default_output = haskey(ENV, "CI") ? job_id : joinpath("output", job_id)
output_dir = parse_arg(parsed_args, "output_dir", default_output)
@info "Output directory: `$output_dir`"
mkpath(output_dir)

function make_save_to_disk_func(output_dir, p, is_distributed)
    function save_to_disk_func(integrator)
        Y = integrator.u

        if :ρq_tot in propertynames(Y.c)
            (; ᶜts, ᶜp, ᶜS_ρq_tot, params, ᶜK, ᶜΦ) = p
        else
            (; ᶜts, ᶜp, params, ᶜK, ᶜΦ) = p
        end

        ᶜuₕ = Y.c.uₕ
        ᶠw = Y.f.w

        # kinetic energy
        @. ᶜK = norm_sqr(C123(ᶜuₕ) + C123(ᶜinterp(ᶠw))) / 2

        # pressure, temperature, potential temperature
        if :ρθ in propertynames(Y.c)
            @. ᶜts = thermo_state_ρθ(Y.c.ρθ, Y.c, params)
        elseif :ρe_tot in propertynames(Y.c)
            @. ᶜts = thermo_state_ρe(Y.c.ρe_tot, Y.c, ᶜK, ᶜΦ, params)
        elseif :ρe_int in propertynames(Y.c)
            @. ᶜts = thermo_state_ρe_int(Y.c.ρe_int, Y.c, params)
        end
        @. ᶜp = TD.air_pressure(params, ᶜts)
        ᶜT = @. TD.air_temperature(params, ᶜts)
        ᶜθ = @. TD.dry_pottemp(params, ᶜts)

        # vorticity 
        curl_uh = @. curlₕ(Y.c.uₕ)
        ᶜvort = Geometry.WVector.(curl_uh)
        Spaces.weighted_dss!(ᶜvort)

        dry_diagnostic = (;
            pressure = ᶜp,
            temperature = ᶜT,
            potential_temperature = ᶜθ,
            kinetic_energy = ᶜK,
            vorticity = ᶜvort,
        )

        # cloudwater (liquid and ice), watervapor, precipitation, and RH for moist simulation
        if :ρq_tot in propertynames(Y.c)
            ᶜq = @. TD.PhasePartition(params, ᶜts)
            ᶜcloud_liquid = @. ᶜq.liq
            ᶜcloud_ice = @. ᶜq.ice
            ᶜwatervapor = @. TD.vapor_specific_humidity(ᶜq)
            ᶜRH = @. TD.relative_humidity(params, ᶜts)

            # precipitation
            @. ᶜS_ρq_tot =
                Y.c.ρ * CM.Microphysics0M.remove_precipitation(
                    params,
                    TD.PhasePartition(params, ᶜts),
                )

            moist_diagnostic = (;
                cloud_liquid = ᶜcloud_liquid,
                cloud_ice = ᶜcloud_ice,
                water_vapor = ᶜwatervapor,
                precipitation_removal = ᶜS_ρq_tot,
                relative_humidity = ᶜRH,
            )
        else
            moist_diagnostic = NamedTuple()
        end

        if vert_diff
            (; dif_flux_uₕ, dif_flux_energy, dif_flux_ρq_tot) = p
            vert_diff_diagnostic = (;
                sfc_flux_momentum = dif_flux_uₕ,
                sfc_flux_energy = dif_flux_energy,
                sfc_evaporation = dif_flux_ρq_tot,
            )
        else
            vert_diff_diagnostic = NamedTuple()
        end

        diagnostic =
            merge(dry_diagnostic, moist_diagnostic, vert_diff_diagnostic)

        day = floor(Int, integrator.t / (60 * 60 * 24))
        sec = Int(mod(integrator.t, 3600 * 24))
        @info "Saving prognostic variables to JLD2 file on day $day second $sec"
        suffix = is_distributed ? "_pid$pid.jld2" : ".jld2"
        output_file = joinpath(output_dir, "day$day.$sec$suffix")
        jldsave(
            output_file;
            t = integrator.t,
            Y = integrator.u,
            diagnostic = diagnostic,
        )
        return nothing
    end
    return save_to_disk_func
end

save_to_disk_func = make_save_to_disk_func(output_dir, p, is_distributed)

dss_callback = FunctionCallingCallback(func_start = true) do Y, t, integrator
    p = integrator.p
    Spaces.weighted_dss_start!(Y.c, p.ghost_buffer.c)
    Spaces.weighted_dss_start!(Y.f, p.ghost_buffer.f)
    Spaces.weighted_dss_internal!(Y.c, p.ghost_buffer.c)
    Spaces.weighted_dss_internal!(Y.f, p.ghost_buffer.f)
    Spaces.weighted_dss_ghost!(Y.c, p.ghost_buffer.c)
    Spaces.weighted_dss_ghost!(Y.f, p.ghost_buffer.f)
end
save_to_disk_callback = if dt_save_to_disk == Inf
    nothing
else
    PeriodicCallback(save_to_disk_func, dt_save_to_disk; initial_affect = true)
end
callback =
    CallbackSet(dss_callback, save_to_disk_callback, additional_callbacks...)

problem = if parsed_args["split_ode"]
    SplitODEProblem(
        ODEFunction(
            implicit_tendency!;
            jac_kwargs...,
            tgrad = (∂Y∂t, Y, p, t) -> (∂Y∂t .= FT(0)),
        ),
        remaining_tendency!,
        Y,
        (t_start, t_end),
        p,
    )
else
    OrdinaryDiffEq.ODEProblem(remaining_tendency!, Y, (t_start, t_end), p)
end
integrator = OrdinaryDiffEq.init(
    problem,
    ode_algorithm(; alg_kwargs...);
    saveat = dt_save_to_sol == Inf ? [] : dt_save_to_sol,
    callback = callback,
    dt = dt,
    adaptive = false,
    progress = show_progress_bar,
    progress_steps = isinteractive() ? 1 : 1000,
    additional_solver_kwargs...,
)

if haskey(ENV, "CI_PERF_SKIP_RUN") # for performance analysis
    throw(:exit_profile)
end
@info "Running job:`$job_id`"
if is_distributed
    OrdinaryDiffEq.step!(integrator)
    ClimaComms.barrier(comms_ctx)
    walltime = @elapsed sol = OrdinaryDiffEq.solve!(integrator)
    ClimaComms.barrier(comms_ctx)
else
    sol = @timev OrdinaryDiffEq.solve!(integrator)
end

if is_distributed # replace sol.u on the root processor with the global sol.u
    if ClimaComms.iamroot(comms_ctx)
        global_h_space = make_horizontal_space(horizontal_mesh, quad, comms_ctx)
        global_center_space, global_face_space =
            make_hybrid_spaces(global_h_space, z_max, z_elem, z_stretch)
        global_Y_c_type = Fields.Field{
            typeof(Fields.field_values(Y.c)),
            typeof(global_center_space),
        }
        global_Y_f_type = Fields.Field{
            typeof(Fields.field_values(Y.f)),
            typeof(global_face_space),
        }
        global_Y_type = Fields.FieldVector{
            FT,
            NamedTuple{(:c, :f), Tuple{global_Y_c_type, global_Y_f_type}},
        }
        global_sol_u = similar(sol.u, global_Y_type)
    end
    for i in 1:length(sol.u)
        global_Y_c =
            DataLayouts.gather(comms_ctx, Fields.field_values(sol.u[i].c))
        global_Y_f =
            DataLayouts.gather(comms_ctx, Fields.field_values(sol.u[i].f))
        if ClimaComms.iamroot(comms_ctx)
            global_sol_u[i] = Fields.FieldVector(
                c = Fields.Field(global_Y_c, global_center_space),
                f = Fields.Field(global_Y_f, global_face_space),
            )
        end
    end
    if ClimaComms.iamroot(comms_ctx)
        sol = DiffEqBase.sensitivity_solution(sol, global_sol_u, sol.t)
        println("walltime = $walltime (seconds)")
        scaling_file =
            joinpath(output_dir, "scaling_data_$(nprocs)_processes.jld2")
        println("writing performance data to $scaling_file")
        jldsave(scaling_file; nprocs, walltime)
    end
end

import JSON
using Test
import OrderedCollections
using ClimaCoreTempestRemap
using ClimaCorePlots, Plots
include(joinpath(@__DIR__, "define_post_processing.jl"))
if !is_distributed
    ENV["GKSwstype"] = "nul" # avoid displaying plots
    if is_baro_wave(parsed_args)
        paperplots_baro_wave(sol, output_dir, p, FT(90), FT(180))
    elseif is_column_radiative_equilibrium(parsed_args)
        custom_postprocessing(sol, output_dir)
    elseif is_column_edmf(parsed_args)
        postprocessing_edmf(sol, output_dir, fps)
    elseif forcing_type() isa HeldSuarezForcing && t_end >= (3600 * 24 * 400)
        paperplots_held_suarez(sol, output_dir, p, FT(90), FT(180))
    else
        postprocessing(sol, output_dir, fps)
    end
end

if !is_distributed || ClimaComms.iamroot(comms_ctx)
    include(joinpath(@__DIR__, "..", "..", "post_processing", "mse_tables.jl"))

    Y_last = sol.u[end]
    # This is helpful for starting up new tables
    @info "Job-specific MSE table format:"
    println("all_best_mse[\"$job_id\"] = OrderedCollections.OrderedDict()")
    for prop_chain in Fields.property_chains(Y_last)
        println("all_best_mse[\"$job_id\"][$prop_chain] = 0.0")
    end
    if parsed_args["regression_test"]

        # Extract best mse for this job:
        best_mse = all_best_mse[job_id]

        include(
            joinpath(@__DIR__, "..", "..", "post_processing", "compute_mse.jl"),
        )

        ds_filename_computed = joinpath(output_dir, "prog_state.nc")

        function process_name(s::AbstractString)
            # "c_ρ", "c_ρe", "c_uₕ_1", "c_uₕ_2", "f_w_1"
            s = replace(s, "components_data_" => "")
            s = replace(s, "ₕ" => "_h")
            s = replace(s, "ρ" => "rho")
            return s
        end
        varname(pc::Tuple) = process_name(join(pc, "_"))

        export_nc(Y_last; nc_filename = ds_filename_computed, varname)
        computed_mse = regression_test(;
            job_id,
            reference_mse = best_mse,
            ds_filename_computed,
            varname,
        )

        computed_mse_filename = joinpath(output_dir, "computed_mse.json")

        open(computed_mse_filename, "w") do io
            JSON.print(io, computed_mse)
        end
        NCRegressionTests.test_mse(computed_mse, best_mse)
    end

end
