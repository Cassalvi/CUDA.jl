using Test, Base.CoreLogging
import Base.CoreLogging: Info

using CUDAnative, CUDAdrv
import Adapt, LLVM

include("util.jl")

# TODO: also run the tests with CuArrays.jl
const CuArray = CUDAnative.CuHostArray

@testset "CUDAnative" begin

@test CUDAnative.functional(true)

CUDAnative.version()
CUDAnative.release()

# ensure CI is using the requested version
if haskey(ENV, "CI") && haskey(ENV, "JULIA_CUDA_VERSION")
  @test CUDAnative.release() == VersionNumber(ENV["JULIA_CUDA_VERSION"])
end

CUDAnative.enable_timings()

# see if we have a device to run tests on
# (do this early so that the codegen tests can target the same compute capability)
@test length(devices()) > 0
if length(devices()) > 0
    # the API shouldn't have been initialized
    @test CuCurrentContext() == nothing

    context_cb = Union{Nothing, CuContext}[nothing for tid in 1:Threads.nthreads()]
    CUDAnative.atcontextswitch() do tid, ctx
        context_cb[tid] = ctx
    end

    task_cb = Union{Nothing, Task}[nothing for tid in 1:Threads.nthreads()]
    CUDAnative.attaskswitch() do tid, task
        task_cb[tid] = task
    end

    # now cause initialization
    ctx = context()
    @test CuCurrentContext() == ctx
    @test device() == CuDevice(0)
    @test context_cb[1] == ctx
    @test task_cb[1] == current_task()

    fill!(context_cb, nothing)
    fill!(task_cb, nothing)

    # ... on a different task
    task = @async begin
        context()
    end
    @test ctx == fetch(task)
    @test context_cb[1] == nothing
    @test task_cb[1] == task

    device!(CuDevice(0))
    device!(CuDevice(0)) do
        nothing
    end

    context!(ctx)
    context!(ctx) do
        nothing
    end

    @test_throws AssertionError device!(0, CUDAdrv.CU_CTX_SCHED_YIELD)

    device_reset!()

    device!(0, CUDAdrv.CU_CTX_SCHED_YIELD)

    # test the device selection functionality
    if length(devices()) > 1
        device!(0)
        device!(1) do
            @test device() == CuDevice(1)
        end
        @test device() == CuDevice(0)

        device!(1)
        @test device() == CuDevice(1)
    end

    # test that each task can work with devices independently from other tasks
    if length(devices()) > 1
        device!(0)
        @test device() == CuDevice(0)

        task = @async begin
            device!(1)
            @test device() == CuDevice(1)
        end
        fetch(task)

        @test device() == CuDevice(0)

        # reset on a task
        task = @async begin
            device!(1)
            device_reset!()
        end
        fetch(task)
        @test device() == CuDevice(0)

        # tasks on multiple threads
        Threads.@threads for d in 0:1
            for x in 1:100  # give threads a chance to trample over each other
                device!(d)
                yield()
                @test device() == CuDevice(d)
                yield()

                sleep(rand(0.001:0.001:0.01))

                device!(1-d)
                yield()
                @test device() == CuDevice(1-d)
                yield()
            end
        end
        @test device() == CuDevice(0)
    end

    # pick a suiteable device
    candidates = [(device!(dev);
                   (dev=dev,
                    cap=capability(dev),
                    mem=CUDAdrv.available_memory()))
                  for dev in devices()]
    ## pick a device that is fully supported by our CUDA installation, or tools can fail
    ## NOTE: we don't reuse target_support which is also bounded by LLVM support,
    #        and is used to pick a codegen target regardless of the actual device.
    cuda_support = CUDAnative.cuda_compat()
    filter!(x->x.cap in cuda_support.cap, candidates)
    ## order by available memory, but also by capability if testing needs to be thorough
    thorough = parse(Bool, get(ENV, "CI_THOROUGH", "false"))
    if thorough
        sort!(candidates, by=x->(x.cap, x.mem))
    else
        sort!(candidates, by=x->x.mem)
    end
    isempty(candidates) && error("Could not find any suitable device for this configuration")
    pick = last(candidates)
    @info("Testing using device $(name(pick.dev)) (compute capability $(pick.cap), $(Base.format_bytes(pick.mem)) available memory) on CUDA driver $(CUDAdrv.version()) and toolkit $(CUDAnative.version())")
    device!(pick.dev)
end

include("base.jl")
include("pointer.jl")
include("codegen.jl")

if isempty(devices())
    @warn("No CUDA-capable devices available; skipping on-device tests.")
else
    if capability(device()) < v"2.0"
        @warn("native execution not supported on SM < 2.0")
    else
        include("device/codegen.jl")
        include("device/execution.jl")
        include("device/pointer.jl")
        include("device/array.jl")
        include("device/cuda.jl")
        include("device/wmma.jl")

        include("nvtx.jl")

        include("examples.jl")
    end
end

haskey(ENV, "CI") && CUDAnative.timings()

end
