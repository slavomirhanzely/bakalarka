using PyPlot
using Polyhedra
using CDDLib
using Convex
using SCS
using Distributions

set_default_solver(SCSSolver(verbose=0))
const ϵ = 1e-24
const δ = 1e-14

function generate_polyeder( dim, no_planes ) # dany Ax≥b
    while true
        A=randn(no_planes, dim)
        b=randn(no_planes)

        x0=rand(dim)*2-ones(dim)
        for i in range(1,no_planes)
            if A[i,:]⋅x0 < b[i]
                A[i,:] *= -1
                b[i] *= -1
            end
        end

        bounded = true
        x = Variable(dim)
        for i=1:2*dim
            if i>dim
                p = maximize(x[i-dim])
            else
                p = minimize(x[i])
            end
            p.constraints += A*x >= b
            solve!(p)
            if !(p.status == :Optimal)
                bounded = false
                break
            end
            # if p.optval*p.optval < 1  # TODO mozno odkomentovat
            #     bounded = false
            #     break
            # end
        end
        if !bounded
            continue
        end

        VRep=collect(Polyhedra.points(polyhedron(hrep(-A,-b), CDDLibrary())))
        vertices=zeros(length(VRep), dim)
        i=1
        for point in VRep
            for j in range(1,length(point))
                vertices[i,j]=point[j]
            end
            i+=1
        end

        Fx = [ones(size(vertices,1)) vertices]
        det_M = det( Fx'*Fx/size(Fx,1) )
        @show det_M
        if det_M < 1e-18
            continue
        end

        # odstran zbytocne rovnice z H reprezentacie
        bounding_set = []
        for i=1:no_planes
            bounds=false
            for j=1:size(vertices, 1)
                if abs(A[i,:]⋅vertices[j,:] - b[i]) <δ
                    bounds=true
                    break
                end
            end
            if bounds
                append!(bounding_set,i)
            end
        end
        # if size(vertices,1)<size(A_reduced,1)+2
        #     continue
        # end
        A_reduced = A[bounding_set,:]
        b_reduced = b[bounding_set]
        return (A_reduced,b_reduced, vertices, x0)
    end
end

function find_MVEE(Fx, γ=4, eff=1-1e-9, it_max=10^12, t_max=30) # pouzitim REX algoritmu
    n = size(Fx,1)
    m = size(Fx,2)
    L = min(n, γ*m)

    w = zeros(n)
    M = zeros(m,m)
    supp=[]
    c=0
    while det(M) < 1e-18
        supp = randperm(n)[m+c:n]
        w[supp] = 1 / length(supp)
        M = (sqrt.(w[supp]) .* Fx[supp,:])'*((sqrt.(w[supp]) .* Fx[supp,:]))
        if m+c==n
            @show c, det(M)
            @show M
            error()
        end
        c+=1
    end
    M=(M+M')/2
    print("det(M): "); print(det(M)); print(" -> ")
    for n_iter = 1:it_max
        K = length(supp)
        w_supp = w[supp]
        M_inv=inv(M)
        d_fun = ((Fx * (chol( (M_inv+M_inv')/2 ))' ).^2) * ones(m) / m
        ord = reverse(sortperm(d_fun))[1:L]
        if d_fun[ord[1]] < 1/eff
            break
        end
        lx_vec = shuffle(ord)
        kx_vec = shuffle(supp)

        n_iter += 1
        kb = supp[ findmin(d_fun[supp])[2] ]
        lb = ord[1]
        v = [kb; lb]
        cv = Fx[v, :] * (M \ Fx[v, :]')
        α = 0.5 * (cv[2, 2] - cv[1, 1])/(cv[1, 1] * cv[2, 2] - cv[1, 2]^2 + δ)
        α = min(w[kb], α)
        w[kb] -= α
        w[lb] += α
        M += α * ((Fx[lb,:])*(Fx[lb,:]') - (Fx[kb,:])*(Fx[kb, :]'))
        M = (M+M')/2    # pre istotu
        for l = 1:L
            lx = lx_vec[l]
            Alx = Fx[lx, :]*Fx[lx, :]'
            for k = 1:K
                kx = kx_vec[k]
                v = [kx; lx]
                cv = Fx[v, :] * (M \ Fx[v, :]')
                α = 0.5 * (cv[2, 2] - cv[1, 1])/(cv[1, 1] * cv[2, 2] - cv[1, 2]^2 + ϵ)
                α = min(w[kx], max(-w[lx], α))
                wkx_temp = w[kx] - α
                wlx_temp = w[lx] + α
                if ((w[kb] >= δ) || (wkx_temp < δ) || (wlx_temp < δ))
                    w[kx] = wkx_temp
                    w[lx] = wlx_temp
                    M += α * (Alx - (Fx[kx,:])*(Fx[kx,:]'))
                    M = (M+M')/2    # pre istotu
                end
            end
        end
        supp = (1:n)[find(λ -> (λ>δ), w)]
    end
    print(det(M)); print(" \n")
    # vypocitaj MVEE
    reg = Fx[:, 2:m]
    Z = zeros(m-1)
    H0 = zeros(m-1,m-1)
    for i=1:n
        Z += w[i]*reg[i,:]
    end
    for i=1:n
        H0 += w[i]*(reg[i,:]-Z)*(reg[i,:]-Z)'
    end
    H=inv(H0)/(m-1)
    return (H,Z)
end

function generate_on_sphere( d )
    x_sym = randn( d )
    return (x_sym/norm(x_sym))
end

function generate_in_ball(d)
    return generate_on_sphere(d)*rand(Uniform(0,1))^(1/d)
end

function gibbs(x, A, b)
    ϵ=1e-14
    for j = 1:size(A,2)
        lb = -10^14
        ub = 10^14
        for l=1:size(A,1)
            if A[l,j] > ϵ
                lb = max(lb, (b[l] -sum(A[l,:]⋅x) +A[l,j]*x[j] ) /A[l,j])
            elseif A[l,j] < -ϵ
                ub = min(ub, (b[l] -sum(A[l,:]⋅x) +A[l,j]*x[j] ) /A[l,j])
            end
        end
        x[j] = rand(Uniform(lb, ub))
    end
    return x
end

burn=100
no_setups = 9
no_polyhedras = 1
no_generated_points = 10^4#5
beg=4

times = zeros(no_setups,5)
size_Hrep = zeros(no_setups)
size_Vrep = zeros(no_setups)
no_generations = zeros(no_setups)
print("\nProgram started\n")
for setup = beg:no_setups  # inicializacia testu
    dimension=setup
    @show dimension
    X=zeros(no_generated_points, dimension) # zoznam vygenerovanych bodov - nie je nutny
    for polyeder = 1:no_polyhedras
        (A,b,vertices,x0)=generate_polyeder(dimension, dimension*10)
        print("Polyhedra generated:  ")
        size_Hrep[setup] = size(A,1)
        size_Vrep[setup] = size(vertices,1)
        @show size_Hrep[setup], size_Vrep[setup]

        # vypocet MVEE
        starttime = time()
        (H,Z)=find_MVEE([ones(size(vertices,1)) vertices])
        H_inv=inv(H)
        C = chol((H_inv+H_inv')/2)
        endtime = time()
        times[setup,4] += endtime - starttime

        # MVEE metoda
        starttime = time()
        for i=1:no_generated_points
            X[i,:] = C*generate_in_ball(dimension)+Z
            count=1
            while any(λ ->(λ< -δ), A*X[i,:]-b)
                X[i,:]=C*generate_in_ball(dimension)+Z
                count += 1
            end
            no_generations[setup] += count
        end
        endtime=time()
        times[setup,1] += endtime-starttime
        no_generations[setup] /= no_generated_points

        # # zrychlena MVEE metoda
        # A2=A*C
        # b2=A*Z-b
        # @show A2
        # @show b2
        # starttime = time()
        # for i=1:no_generated_points
        #     x_G = generate_in_ball(dimension)
        #     while any(λ ->(λ< -δ), A2*x_G-b2)
        #         # @show A2*x_G-b2
        #         x_G = generate_in_ball(dimension)
        #     end
        #     X[i,:] = C*x_G+Z
        # end
        # endtime=time()
        # times[setup,5] += endtime-starttime

        # Hit-and-Run generator
        starttime=time()
        w=zeros(size(A,1))
        x=deepcopy(x0)
        for i=(1-burn):no_generated_points
            D = generate_on_sphere(size(A,2))

            for j=1:size(A,1)
                w[j]=(A[j,:]⋅x-b[j])/(A[j,:]⋅D)
            end

            w_neg = filter(λ->(λ<-ϵ), w)
            lb=0
            if length(w_neg)>0
                lb = maximum(w_neg)
            end
            w_pos = filter(λ->(λ>ϵ), w)
            ub=0
            if length(w_pos)>0
                ub = minimum(w_pos)
            end

            dist=rand(Uniform(lb,ub))
            x -= dist*D
            if i>0
                X[i,:] = x
            end
        end
        X = X[shuffle(1:end), :]
        endtime = time()
        times[setup,2] += endtime-starttime

        # Gibbs generator
        starttime = time()
        x_next = deepcopy(x0)
        for i=(1-burn):no_generated_points
            x=x_next
            x_next = gibbs(x, A, b)
            if i>0
                X[i,:]=x
            end
        end
        X = X[shuffle(1:end), :]
        endtime = time()
        times[setup,3] += endtime-starttime

        print("Polyhedra tested\n")
    end
    times[setup,:] /= no_polyhedras
    print("Dimension done\n")
end

# ukladanie vysledkov

# scatter(beg:no_setups, size_Hrep[beg:end], label="H-reprezentácia")
# scatter(beg:no_setups, size_Vrep[beg:end], label="V-reprezentácia")
# xlabel("rozmer priestoru")
# ylabel("priemerná veľkosť reprezentácii")
# legend()
# savefig("images/velkost_rep")
# close()

# scatter(beg:no_setups, size_Vrep[beg:end] ./ size_Hrep[beg:end], label="pomer veľkostí reprezentácií")
# xlabel("rozmer priestoru")
# ylabel("priemerná veľkosti H-reprezentacie ku V reprezentácie")
# legend()
# savefig("images/pomer_rep")
# close()

# scatter(beg:no_setups, no_generations[beg:end], label="MVEE metóda")
# xlabel("rozmer priestoru")
# ylabel("pocet pokusov")
# legend()
# savefig("images/mvee_pokusy")
# close()

scatter(beg:no_setups, times[beg:end,1], label="MVEE metóda")
scatter(beg:no_setups, times[beg:end,5], label="zrýchlená MVEE metóda")
scatter(beg:no_setups, times[beg:end,2], label="Hit-and-Run")
scatter(beg:no_setups, times[beg:end,3], label="Gibbs")
scatter(beg:no_setups, times[beg:end,4], label="beh REX algoritmu (jednorázový)")
xlabel("rozmer priestoru")
ylabel("priemerný čas vygenerovania bodu [ns]")
legend()
# savefig("images/vsetky")
# savefig("images/mh")
# savefig("images/mh_rex")
# close()
