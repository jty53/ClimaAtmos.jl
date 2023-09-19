#####
##### EDMF entrainment detrainment
#####

"""
   Return entrainment rate [1/s].

   Inputs (everything defined on cell centers):
   - params set with model parameters
   - ᶜz, z_sfc, ᶜp, ᶜρ, - grid-scale height, surface height, grid-scale pressure and density
   - buoy_flux_surface - buoyancy flux at the surface
   - ᶜaʲ, ᶜwʲ, ᶜRHʲ, ᶜbuoyʲ - updraft area, physical vertical velocity,
                                   relative humidity and buoyancy
   - ᶜw⁰, ᶜRH⁰, ᶜbuoy⁰ - environment physical vertical velocity,
                              relative humidity and buoyancy
   - dt - timestep
"""

function entrainment(
    params,
    ᶜz::FT,
    z_sfc::FT,
    ᶜp::FT,
    ᶜρ::FT,
    buoy_flux_surface::FT,
    ᶜaʲ::FT,
    ᶜwʲ::FT,
    ᶜRHʲ::FT,
    ᶜbuoyʲ::FT,
    ᶜw⁰::FT,
    ᶜRH⁰::FT,
    ᶜbuoy⁰::FT,
    dt::FT,
    ::NoEntrainment,
) where {FT}
    return FT(0)
end

function entrainment(
    params,
    ᶜz::FT,
    z_sfc::FT,
    ᶜp::FT,
    ᶜρ::FT,
    buoy_flux_surface::FT,
    ᶜaʲ::FT,
    ᶜwʲ::FT,
    ᶜRHʲ::FT,
    ᶜbuoyʲ::FT,
    ᶜw⁰::FT,
    ᶜRH⁰::FT,
    ᶜbuoy⁰::FT,
    dt::FT,
    ::PiGroupsEntrainment,
) where {FT}
    if ᶜaʲ <= FT(0)
        return FT(0)
    else
        g = CAP.grav(params)
        turbconv_params = CAP.turbconv_params(params)
        ᶜaʲ_max = TCP.max_area(turbconv_params)

        # pressure scale height (height where pressure drops by 1/e)
        ref_H = ᶜp / (ᶜρ * g)
        # convective velocity
        w_star = get_wstar(buoy_flux_surface)

        # non-dimensional pi-groups
        # TODO - using Π₁ blows things up
        Π₁ =
            (ᶜz - z_sfc) * (ᶜbuoyʲ - ᶜbuoy⁰) /
            ((ᶜwʲ - ᶜw⁰)^2 + w_star^2 + eps(FT))
        Π₃ = sqrt(ᶜaʲ)
        Π₄ = ᶜRHʲ - ᶜRH⁰
        Π₆ = (ᶜz - z_sfc) / ref_H
        entr = max(
            0,
            min(
                abs(ᶜwʲ) / (ᶜz - z_sfc) * (
                    -4.013288 - 0.000968 * Π₁ + 0.356974 * Π₃ - 0.403124 * Π₄ + 1.503261 * Π₆
                ),
                1 / dt,
            ),
        )

        return entr
    end
end

function entrainment(
    params,
    ᶜz::FT,
    z_sfc::FT,
    ᶜp::FT,
    ᶜρ::FT,
    buoy_flux_surface::FT,
    ᶜaʲ::FT,
    ᶜwʲ::FT,
    ᶜRHʲ::FT,
    ᶜbuoyʲ::FT,
    ᶜw⁰::FT,
    ᶜRH⁰::FT,
    ᶜbuoy⁰::FT,
    dt::FT,
    ::ConstantCoefficientEntrainment,
) where {FT}
    if ᶜaʲ <= FT(0)
        return FT(0)
    else
        entr_coeff = CAP.entr_coeff(params)
        entr = max(0, min(entr_coeff * abs(ᶜwʲ) / (ᶜz - z_sfc), 1 / dt))
        return entr
    end
end

function entrainment(
    params,
    ᶜz::FT,
    z_sfc::FT,
    ᶜp::FT,
    ᶜρ::FT,
    buoy_flux_surface::FT,
    ᶜaʲ::FT,
    ᶜwʲ::FT,
    ᶜRHʲ::FT,
    ᶜbuoyʲ::FT,
    ᶜw⁰::FT,
    ᶜRH⁰::FT,
    ᶜbuoy⁰::FT,
    dt::FT,
    ::ConstantTimescaleEntrainment,
) where {FT}
    if ᶜaʲ <= FT(0)
        return FT(0)
    else
        entr_tau = CAP.entr_tau(params)
        entr = max(0, min(1 / entr_tau, 1 / dt))
        return entr
    end
end

"""
   Return detrainment rate [1/s].

   Inputs (everything defined on cell centers):
   - params set with model parameters
   - ᶜz, z_sfc, ᶜp, ᶜρ, - grid-scale height, surface height, grid-scale pressure and density
   - buoy_flux_surface - buoyancy flux at the surface
   - ᶜaʲ, ᶜwʲ, ᶜRHʲ, ᶜbuoyʲ - updraft area, physical vertical velocity,
                                   relative humidity and buoyancy
   - ᶜw⁰, ᶜRH⁰, ᶜbuoy⁰ - environment physical vertical velocity,
                              relative humidity and buoyancy
   - dt - timestep
"""
function detrainment(
    params,
    ᶜz::FT,
    z_sfc::FT,
    ᶜp::FT,
    ᶜρ::FT,
    buoy_flux_surface::FT,
    ᶜaʲ::FT,
    ᶜwʲ::FT,
    ᶜRHʲ::FT,
    ᶜbuoyʲ::FT,
    ᶜw⁰::FT,
    ᶜRH⁰::FT,
    ᶜbuoy⁰::FT,
    dt::FT,
    ::NoDetrainment,
) where {FT}
    return FT(0)
end

function detrainment(
    params,
    ᶜz::FT,
    z_sfc::FT,
    ᶜp::FT,
    ᶜρ::FT,
    buoy_flux_surface::FT,
    ᶜaʲ::FT,
    ᶜwʲ::FT,
    ᶜRHʲ::FT,
    ᶜbuoyʲ::FT,
    ᶜw⁰::FT,
    ᶜRH⁰::FT,
    ᶜbuoy⁰::FT,
    dt::FT,
    ::PiGroupsDetrainment,
) where {FT}

    if ᶜaʲ <= FT(0)
        return FT(0)
    else
        g = CAP.grav(params)
        turbconv_params = CAP.turbconv_params(params)
        ᶜaʲ_max = TCP.max_area(turbconv_params)
        max_area_limiter = 0.1 * exp(-10 * (ᶜaʲ_max - ᶜaʲ))

        # pressure scale height (height where pressure drops by 1/e)
        ref_H = ᶜp / (ᶜρ * g)
        # convective velocity
        w_star = get_wstar(buoy_flux_surface)

        # non-dimensional pi-groups
        # TODO - using Π₁ blows things up
        Π₁ =
            (ᶜz - z_sfc) * (ᶜbuoyʲ - ᶜbuoy⁰) /
            ((ᶜwʲ - ᶜw⁰)^2 + w_star^2 + eps(FT))
        Π₃ = sqrt(ᶜaʲ)
        Π₄ = ᶜRHʲ - ᶜRH⁰
        Π₆ = (ᶜz - z_sfc) / ref_H
        detr = max(
            0,
            min(
                abs(ᶜwʲ) * (
                    3.535208 + 0.598496 * Π₁ + 1.583348 * Π₃ + 0.046275 * Π₄ - 0.344836 * Π₆ + max_area_limiter
                ),
                1 / dt,
            ),
        )
        return detr
    end
end

function detrainment(
    params,
    ᶜz::FT,
    z_sfc::FT,
    ᶜp::FT,
    ᶜρ::FT,
    buoy_flux_surface::FT,
    ᶜaʲ::FT,
    ᶜwʲ::FT,
    ᶜRHʲ::FT,
    ᶜbuoyʲ::FT,
    ᶜw⁰::FT,
    ᶜRH⁰::FT,
    ᶜbuoy⁰::FT,
    dt::FT,
    ::ConstantCoefficientDetrainment,
) where {FT}

    if ᶜaʲ <= FT(0)
        return FT(0)
    else
        detr_coeff = CAP.detr_coeff(params)
        detr = max(0, min(detr_coeff * abs(ᶜwʲ), 1 / dt))
        return detr
    end
end

edmfx_entr_detr_tendency!(Yₜ, Y, p, t, colidx, turbconv_model) = nothing
function edmfx_entr_detr_tendency!(Yₜ, Y, p, t, colidx, turbconv_model::EDMFX)

    n = n_mass_flux_subdomains(turbconv_model)
    (; ᶜspecificʲs, ᶜh_totʲs, ᶜentrʲs, ᶜdetrʲs) = p
    (; ᶜu⁰, ᶜspecific⁰, ᶜh_tot⁰) = p

    for j in 1:n

        @. Yₜ.c.sgsʲs.:($$j).ρa[colidx] +=
            Y.c.sgsʲs.:($$j).ρa[colidx] *
            (ᶜentrʲs.:($$j)[colidx] - ᶜdetrʲs.:($$j)[colidx])

        @. Yₜ.c.sgsʲs.:($$j).ρae_tot[colidx] +=
            Y.c.sgsʲs.:($$j).ρa[colidx] * (
                ᶜentrʲs.:($$j)[colidx] * ᶜh_tot⁰[colidx] -
                ᶜdetrʲs.:($$j)[colidx] * ᶜh_totʲs.:($$j)[colidx]
            )

        @. Yₜ.c.sgsʲs.:($$j).ρaq_tot[colidx] +=
            Y.c.sgsʲs.:($$j).ρa[colidx] * (
                ᶜentrʲs.:($$j)[colidx] * ᶜspecific⁰.q_tot[colidx] -
                ᶜdetrʲs.:($$j)[colidx] * ᶜspecificʲs.:($$j).q_tot[colidx]
            )

        @. Yₜ.f.sgsʲs.:($$j).u₃[colidx] +=
            ᶠinterp(ᶜentrʲs.:($$j)[colidx] * C3(ᶜu⁰[colidx])) -
            ᶠinterp(ᶜentrʲs.:($$j)[colidx]) * Y.f.sgsʲs.:($$j).u₃[colidx]
    end
    return nothing
end
