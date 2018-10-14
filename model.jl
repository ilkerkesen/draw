using Knet
using ArgParse

# terms
# g, gx, gy: grid centers
# NxN: gaussian filter size
# delta: stride
# AxB: image size
# rng: randomly sampled matrix


include(Pkg.dir("Knet","examples","variational-autoencoder", "vae_mnist.jl"))

function filterbank(gx, gx, sigma2, delta, A, B)
    rng = randn!(similar(mu))
    mu_x = compute_mu(gx, rng, delta)
    mu_y = compute_mu(gy, rng, delta)

    atype = typeof(AutoGrad.getval(gx)) <: KnetArray ? KnetArray : Array
    etype = atype <: KnetArray ? Float32 : Float64
    a = convert(atype{etype}, reshape(collect(1:A), A, 1))
    b = convert(atype{etype}, reshape(collect(1:B), B, 1))

    Fx = get_filterbank_matrices(a, mu_x, sigma2)
    Fy = get_filterbank_matrices(b, mu_y, sigma2)

    return Fx, Fy
end


function get_filterbank_matrices(a, mu_x, sigma2, epsilon=1e-9)
    F = -((a .- mu_x) / 2sigma2).^2
    F = F/(sum(F,2)+epsilon)
end


function compute_mu(g, rng, delta, N)
    mu = (rng .- N / 2 - 0.5) * delta .+ g
    mu = reshape(mu, N, 1)
end


function attn_window(w, hdec, A, B)
    params = w[:wparams] * hdec
    gx_ = params[1]
    gy_ = params[2]
    logsigma2 = params[3]
    logdelta = params[4]
    loggamma = params[5]

    gx = (A+1)/2*(gx_+1)
    gy = (B+1)/2*(gy_+1)
    delta = (max(A,B)-1)/(N-1) * exp.(logdelta)
    sigma2 = exp(logsigma2)
    gamma = exp(loggamma)

    return filterbank(gx,gy,sigma2,delta),gamma
end


function draw_read(w, x, xhat, hdec, A, B, N)
    vcat(x, xhat)
end


function draw_write(w, hdec)
    w[:wattnw] * hdec .+ w[:battnw]
end


function qnet(w,henc)
    mu = w[:wmu] * henc .+ w[:bmu]
    logsigma = w[:wlogsigma] * henc .+ w[:blogsigma]
    sigma = exp.(logsigma)
    noise = randn!(similar(mu))
    return mu .+ noise .* sigma
end


function reconstruct(w, r, x, o)
    mus = []; logsigmas = []; sigmas = []; cs = []
    A, B, T, N = o[:A], o[:B], o[:T], o[:N]

    c = 0.0
    xhat = x - sigm(c)
    rt = draw_read(x, o)
    henc, cenc = rnnforw(r,w,rt; hy=true, cy=true)
    z, mu, logsigma, sigma = qnet(w, henc)
    push!(mus, mu); push!(logsigmas, logsigma); push!(sigmas, sigma)
    hdec, cdec = rnnforw(r,w,z; hy=true, cy=true)
    wt = draw_write(hdec)
    c = c .+ wt
    push!(cs, c)

    for t=2:o[:T]
        xhat = x - sigm(c)
        rt = draw_read(w, x, xhat, hdec, A, B, N)
        henc, cenc = rnnforw(r, w, rt, henc, cenc; hy=true, cy=true)
        z, mu, logsigma, sigma = qnet(henc)
        push!(mus, mu); push!(logsigmas, logsigma); push!(sigmas, sigma)
        hdec, cdec = rnnforw(r, w, z, hdec, cdec; hy=true, cy=true)
        wt = draw_write(hdec)
        c = c .+ wt
        push!(cs, c)
    end

    return mus, logsigmas, sigmas, cs
end


function generate(w,r,o)
    cs = []
    hdec = cdec = cprev = nothing
    for t = 1:o[:T]
        z = convert(o[:atype], randn(o[:zdim], o[:batchsize]))
        if t == 1
            cprev = 0.0
            hdec, cdec = rnnforw(r, w, z; hy=true, cy=true)
        else
            cprev = cs[end]
            hdec, cdec = rnnforw(r, w, z, hdec, cdec)
        end
        push!(cs, cprev .+ draw_write(w,hdec))
    end

    cs = map(x->sigm.(x), cs)
    cs = map(x->convert(o[:atype], x), )
end


function loss(w, r, x, o)
    A, B, T = o[:A], o[:B], o[:T]
    mus, logsigmas, sigmas, cs = reconstruct(w, r, x, o)
    xhat = sigm.(cs[end])
    Lx = VAE.binary_cross_entropy(x, xhat) * A * B
    Lz = 0
    for t = 1:T
        mu_2 = mus[t] * mus[t]
        sigma_2 = sigmas[t] * sigmas[t]
        logsigma = logsigmas[t]
        Lz += 0.5 * sum(mu_2 * sigma_2-2logsigma, 1) - 0.5T
    end
    Lz = mean(Lz)
    return Lx + Lz
end


function load_weights(w, o)

end

function main(args)
    o = parse_options(args)
    o[:seed] > 0 && Knet.setseed(o[:seed])

    w = load_weights(w, o)
end


function parse_options(args)
    s = ArgParseSettings()
    s.description = "DRAW model on MNIST."

    @add_arg_table s begin
        ("--atype"; default=(gpu()>=0?"KnetArray{Float32}":"Array{Float32}");
         help="array and float type to use")
        ("--batchsize"; arg_type=Int; default=10; help="batch size")
        ("--zdim"; arg_type=Int; default=100; help="noise dimension")
        ("--hdim"; arg_type=Int; default=256; help="hidden units")
        ("--epochs"; arg_type=Int; default=20; help="# of training epochs")
        ("--seed"; arg_type=Int; default=-1; help="random seed")
        ("--gridsize"; arg_type=Int; nargs=2; default=[9,9])
        ("--gridscale"; arg_type=Float64; default=2.0)
        ("--optim"; default="Adam()")
        ("--loadfile"; default=nothing; help="file to load trained models")
        ("--outdir"; default=nothing; help="output dir for models/generations")
        ("--T"; arg_type=Int; default=10)
        ("--A"; arg_type=Int; default=28)
        ("--B"; arg_type=Int; default=28)
        ("--N"; arg_type=Int; default=5)
    end

    isa(args, AbstractString) && (args=split(args))
    o = parse_args(args, s; as_symbols=true)
    o[:atype] = eval(parse(o[:atype]))
    if o[:outdir] != nothing
        o[:outdir] = abspath(o[:outdir])
    end
    return o
end