"""
```
smc(m::AbstractModel, data::Matrix; verbose::Symbol, old_data::Matrix)
smc(m::AbstractModel, data::DataFrame)
smc(m::AbstractModel)
```

### Arguments:

- `m`: A model object, which stores parameter values, prior dists, bounds, and various
    other settings that will be referenced
- `data`: A matrix or dataframe containing the time series of the observables used in
    the calculation of the posterior/likelihood
- `old_data`: A matrix containing the time series of observables of previous data
    (with `data` being the new data) for the purposes of a time tempered estimation
    (that is, using the posterior draws from a previous estimation as the initial set
    of draws for an estimation with new data)

### Keyword Arguments:
- `verbose`: Desired frequency of function progress messages printed to standard out.
	- `:none`: No status updates will be reported.
	- `:low`: Status updates for SMC initialization and recursion will be included.
	- `:high`: Status updates for every iteration of SMC is output, which includes
    the mean and standard deviation of each parameter draw after each iteration,
    as well as calculated acceptance rate, ESS, and number of times resampled.

### Outputs

- `cloud`: The ParticleCloud object containing all of the information about the
    parameter values from the sample, their respective log-likelihoods, the ESS
    schedule, tempering schedule etc., which is saved in the saveroot.

### Overview

Sequential Monte Carlo can be used in lieu of Random Walk Metropolis Hastings to
    generate parameter samples from high-dimensional parameter spaces using
    sequentially constructed proposal densities to be used in iterative importance
    sampling.

The implementation here is based on Edward Herbst and Frank Schorfheide's 2014 paper
    'Sequential Monte Carlo Sampling for DSGE Models' and the code accompanying their
    book 'Bayesian Estimation of DSGE Models'.

SMC is broken up into three main steps:

- `Correction`: Reweight the particles from stage n-1 by defining incremental weights,
    which gradually "temper in" the likelihood function p(Y|θ)^(ϕ_n - ϕ_n-1) into the
    normalized particle weights.
- `Selection`: Resample the particles if the distribution of particles begins to
    degenerate, according to a tolerance level for the ESS.
- `Mutation`: Propagate particles {θ(i), W(n)} via N(MH) steps of a Metropolis
    Hastings algorithm.
"""
function smc(m::AbstractModel, data::Matrix{Float64}; verbose::Symbol = :low,
             old_data::Matrix{Float64} = Matrix{Float64}(undef, size(data, 1), 0),
             old_cloud::ParticleCloud = ParticleCloud(m, 0), run_test::Bool = false)
    ##################################################################################
    ### Setting Parameters
    ##################################################################################

    # General
    parallel = get_setting(m, :use_parallel_workers)
    n_parts  = get_setting(m, :n_particles)
    n_params = n_parameters(m)
    n_blocks = get_setting(m, :n_smc_blocks)
    n_steps  = get_setting(m, :n_mh_steps_smc)

    use_chand_recursion = get_setting(m, :use_chand_recursion)

    if any(isnan.(data)) & use_chand_recursion
        error("Cannot use Chandrasekhar recursions with missing data")
    end

    # Time Tempering
    tempered_update = !isempty(old_data)

    # Check that if there's a tempered update, old and current vintages are different
    if tempered_update
        old_vintage = get_setting(m, :previous_data_vintage)
        @assert old_vintage != data_vintage(m)
    end

    # Step 0 (ϕ schedule) settings
    i = 1                   # Index tracking the stage of the algorithm
    j = 2                   # Index tracking the fixed_schedule entry ϕ_prop is set as
    resampled_last_period = false # Ensures proper resetting of ESS_bar after resample
    ϕ_n = 0.                      # Instantiate ϕ_n and ϕ_prop variables for
    ϕ_prop = 0.                   # reference in respective while loop conditions
    use_fixed_schedule = get_setting(m, :adaptive_tempering_target_smc) == 0.0
    λ = get_setting(m, :λ)
    n_Φ = get_setting(m, :n_Φ)
    tempering_target = get_setting(m, :adaptive_tempering_target_smc)

    # Step 2 (Correction) settings
    resampling_method = get_setting(m, :resampler_smc)
    threshold_ratio   = get_setting(m, :resampling_threshold)
    threshold         = threshold_ratio * n_parts

    # Step 3 (Mutation) settings
    c      = get_setting(m, :step_size_smc)
    target = accept = get_setting(m, :target_accept)
    α      = get_setting(m, :mixture_proportion)

    fixed_para_inds = findall([θ.fixed for θ in m.parameters])
    free_para_inds  = findall([!θ.fixed for θ in m.parameters])
    n_free_para     = length(free_para_inds)

    #################################################################################
    ### Initialize Algorithm: Draws from prior
    #################################################################################

    if VERBOSITY[verbose] >= VERBOSITY[:low]
        if m.testing
            println("\n\n SMC testing starts ....  \n\n  ")
        else
            println("\n\n SMC starts ....  \n\n  ")
        end
    end

    if tempered_update
        if isempty(old_cloud)
            # Load previous ParticleCloud as the starting point for time tempering
            loadpath = rawpath(m, "estimate", "smc_cloud.jld2")
            #loadpath = rawpath(m,"estimate","smc_cloud.jld2",
            #                   ["adpt="*string(tempering_target)])
            loadpath = replace(loadpath, r"vint=[0-9]{6}", "vint="*old_vintage)

            cloud = load(loadpath, "cloud")
        else
            cloud = old_cloud
        end
        initialize_cloud_settings!(m, cloud; tempered_update = tempered_update)
        initialize_likelihoods!(m, data, cloud, parallel = parallel,
                                verbose = verbose)
    else
        # Instantiating ParticleCloud object
        cloud = ParticleCloud(m, n_parts)

        # Modifies the cloud object in place to update draws, loglh, & logpost
        initial_draw!(m, data, cloud, parallel = parallel,
                      use_chand_recursion = use_chand_recursion, verbose = verbose)

        initialize_cloud_settings!(m, cloud; tempered_update = tempered_update)
    end

    # Fixed schedule for construction of ϕ_prop
    if use_fixed_schedule
        cloud.tempering_schedule = ((collect(1:n_Φ) .- 1) / (n_Φ-1)) .^ λ
    else
        proposed_fixed_schedule  = ((collect(1:n_Φ) .- 1) / (n_Φ-1)) .^ λ
    end

    # Instantiate incremental and normalized weight matrices for logMDD calculation
    w_matrix = zeros(n_parts, 1)
    if tempered_update
        W_matrix = similar(w_matrix)
        for k in 1:n_parts
            W_matrix[k] = cloud.particles[k].weight
        end
    else
        W_matrix = fill(1/n_parts, (n_parts,1))
    end
    z_matrix = ones(1)

    if VERBOSITY[verbose] >= VERBOSITY[:low]
        init_stage_print(cloud; verbose = verbose,
                         use_fixed_schedule = use_fixed_schedule)
    end

    #################################################################################
    ### Recursion
    #################################################################################
    if VERBOSITY[verbose] >= VERBOSITY[:low]
        println("\n\n SMC recursion starts \n\n")
    end

    while ϕ_n < 1.

        start_time = time_ns()
        cloud.stage_index = i += 1

        #############################################################################
        ### Step 0: Setting ϕ_n (either adaptively or by the fixed schedule)
        #############################################################################
        ϕ_n1 = cloud.tempering_schedule[i-1]

        if use_fixed_schedule
            ϕ_n = cloud.tempering_schedule[i]
        else
            ϕ_n, resampled_last_period, j, ϕ_prop = solve_adaptive_ϕ(cloud,
                                                       proposed_fixed_schedule,
                                                       i, j, ϕ_prop, ϕ_n1,
                                                       tempering_target,
                                                       resampled_last_period)
        end

        #############################################################################
        ### Step 1: Correction
        #############################################################################
        # Calculate incremental weights (if no old data, get_old_loglh(cloud) = 0)
        incremental_weights = exp.((ϕ_n1 - ϕ_n) * get_old_loglh(cloud) +
                                   (ϕ_n - ϕ_n1) * get_loglh(cloud))

        # Update weights
        update_weights!(cloud, incremental_weights)
        mult_weights = get_weights(cloud)

        # Normalize weights
        normalize_weights!(cloud)
        normalized_weights = get_weights(cloud)

        push!(z_matrix, sum(mult_weights))
        w_matrix = hcat(w_matrix, incremental_weights)
        W_matrix = hcat(W_matrix, normalized_weights)

        ##############################################################################
        ### Step 2: Selection
        ##############################################################################

        # Calculate the degeneracy/effective sample size metric
        push!(cloud.ESS, 1/sum(normalized_weights.^2))

        # If this assertion does not hold then there are likely too few particles
        @assert !isnan(cloud.ESS[i]) "no particles have non-zero weight"

        # Resample if degeneracy/ESS metric falls below the accepted threshold
        if (cloud.ESS[i] < threshold)
            new_inds = resample(normalized_weights; method = resampling_method)
            # update parameters/logpost/loglh with resampled values
            cloud.particles = [deepcopy(cloud.particles[i]) for i in new_inds]
            reset_weights!(cloud) # reset the weights to 1/n_parts
            cloud.resamples += 1
            resampled_last_period = true
            W_matrix[:, i] = fill(1/n_parts, (n_parts,1))
        end

        ##############################################################################
        ### Step 3: Mutation
        ##############################################################################

        # Calculate adaptive c-step for use as scaling coefficient in mutation MH step
        c = c*(0.95 + 0.10*exp(16 .*(cloud.accept - target)) / (1.
                                     + exp(16 .*(cloud.accept - target))))
        cloud.c = c

        θ_bar = weighted_mean(cloud)
        R     = weighted_cov(cloud)

        # Ensures marix is positive semi-definite symmetric
        # (not off due to numerical error) and values haven't changed
        R_fr = (R[free_para_inds, free_para_inds] +
                R[free_para_inds, free_para_inds]') / 2

        # MvNormal centered at ̄θ with var-cov ̄Σ, subsetting out the fixed parameters
        d = MvNormal(θ_bar[free_para_inds], R_fr)

        # New way of generating blocks
        blocks_free = generate_free_blocks(n_free_para, n_blocks)
        blocks_all  = generate_all_blocks(blocks_free, free_para_inds)

        if parallel
            new_particles = @distributed (vcat) for k in 1:n_parts
                mutation(m, data, cloud.particles[k], d, blocks_free, blocks_all,
                         ϕ_n, ϕ_n1; c = c, α = α, old_data = old_data,
                         use_chand_recursion = use_chand_recursion, verbose = verbose)
            end
        else
            new_particles = [mutation(m, data, cloud.particles[k], d, blocks_free,
                                      blocks_all, ϕ_n, ϕ_n1; c = c, α = α,
                                      old_data = old_data,
                                      use_chand_recursion = use_chand_recursion,
                                      verbose = verbose) for k=1:n_parts]
        end

        cloud.particles = new_particles
        update_acceptance_rate!(cloud) # Update average acceptance rate

        ##############################################################################
        ### Timekeeping and Output Generation
        ##############################################################################
        total_time = Float64((time_ns()-start_time)*1e-9)
        cloud.total_sampling_time += total_time

        if VERBOSITY[verbose] >= VERBOSITY[:low]
            end_stage_print(cloud; verbose = verbose,
                            use_fixed_schedule = use_fixed_schedule)
        end

        if run_test && (i == 2)
            break
        end
    end

    ##################################################################################
    ### Saving data
    ##################################################################################

    if !m.testing || run_test
        simfile = h5open(rawpath(m, "estimate", "smcsave.h5"), "w")
        #simfile = h5open(rawpath(m, "estimate", "smcsave.h5",
        #                         ["adpt="*string(tempering_target)]),"w")
        particle_store = d_create(simfile, "smcparams", datatype(Float32),
                                  dataspace(n_parts, n_params))
        for i in 1:length(cloud)
            particle_store[i,:] = cloud.particles[i].value
        end
        close(simfile)
        #jld2open(rawpath(m, "estimate", "smc_cloud.jld2",
        #                 ["adpt="*string(tempering_target)]), "w") do file
        JLD2.jldopen(rawpath(m, "estimate", "smc_cloud.jld2"),
                     true, true, true, IOStream) do file
            write(file, "cloud", cloud)
            write(file, "w", w_matrix)
            write(file, "W", W_matrix)
            write(file, "z", z_matrix)
        end
    end
end

function smc(m::AbstractModel, data::DataFrame; verbose::Symbol=:low)
    data_mat = df_to_matrix(m, data)
    return smc(m, data_mat, verbose=verbose)
end

function smc(m::AbstractModel; verbose::Symbol=:low)
    data = load_data(m)
    data_mat = df_to_matrix(m, data)
    return smc(m, data_mat, verbose=verbose)
end
