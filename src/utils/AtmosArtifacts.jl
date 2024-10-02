module AtmosArtifacts

import Artifacts
import LazyArtifacts
import ClimaUtilities.ClimaArtifacts: @clima_artifact

# There seems to be no easy way to determine if an artifact exists from the name
# only...
function _artifact_exists(name)
    return try
        Artifacts.@artifact_str(name)
        true
    catch error
        false
    end
end


"""
    res_file_path(name; context)

Construct the file path for a file (e.g., NetCDF).

It checks if an artifact with the given `name` is available. If it is, it uses
that name. Otherwise, it appends "_lowres" to the `name`. It then constructs the
full path to the NetCDF file.

The assumption is that the `name` artifact is high resolution and cannot
downloaded, and the `lowres` artifact can always be downloaded.

The ClimaComms context is needed for lazy artifacts with MPI simulations.

# Returns
- The full path to the NetCDF file.
"""
function res_file_path(name; context = nothing)
    if _artifact_exists(name)
        full_name = name
    else
        @warn "Higher resolution $name is not available. Using low-res version. Consult ClimaArtifacts to acquire the higher resolution version."
        full_name = "$(name)_lowres"
    end
    return joinpath(@clima_artifact(full_name, context), "$(full_name).nc")
end

"""
    ozone_concentration_file_path(; context = nothing)

Construct the file path for the ozone concentration NetCDF file.

When available, use the high resolution artifact. Otherwise, download and use
the low-resolution one.
"""
function ozone_concentration_file_path(; context = nothing)
    return res_file_path("ozone_concentrations"; context)
end

"""
    aerosol_concentration_file_path(; context = nothing)

Construct the file path for the aerosol concentration NetCDF file.

When available, use the high resolution artifact. Otherwise, download and use
the low-resolution one.
"""
function aerosol_concentration_file_path(; context = nothing)
    return res_file_path("aerosol_concentrations"; context)
end

end