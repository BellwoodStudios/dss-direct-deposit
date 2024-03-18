all         :; FOUNDRY_OPTIMIZER=true FOUNDRY_OPTIMIZER_RUNS=200 forge build --use solc:0.8.14
clean       :; forge clean
certora-hub :; PATH=~/.solc-select/artifacts/solc-0.8.14:~/.solc-select/artifacts/solc-0.5.12:~/.solc-select/artifacts:${PATH} \
	certoraRun \
	src/D3MHub.sol certora/dss/Vat.sol certora/dss/DaiJoin.sol certora/dss/Dai.sol certora/dss/End.sol certora/d3m/D3MTestPlan.sol certora/d3m/D3MTestPool.sol src/tests/mocks/TokenMock.sol \
	--verify D3MHub:certora/D3MHub.spec \
	--solc_map D3MHub=solc-0.8.14,Vat=solc-0.5.12,DaiJoin=solc-0.5.12,Dai=solc-0.5.12,End=solc-0.5.12,D3MTestPlan=solc-0.8.14,D3MTestPool=solc-0.8.14,TokenMock=solc-0.8.14 \
	--solc_optimize_map D3MHub=200,Vat=0,DaiJoin=0,Dai=0,End=0,D3MTestPlan=200,D3MTestPool=200,TokenMock=200 \
	--rule_sanity basic \
	--link D3MHub:vat=Vat D3MHub:daiJoin=DaiJoin D3MHub:end=End DaiJoin:vat=Vat DaiJoin:dai=Dai End:vat=Vat D3MTestPlan:dai=Dai D3MTestPool:hub=D3MHub D3MTestPool:vat=Vat D3MTestPool:dai=Dai D3MTestPool:share=TokenMock \
	--struct_link D3MHub:pool=D3MTestPool D3MHub:plan=D3MTestPlan \
	--prover_args '-mediumTimeout 1200' '-solver z3' '-adaptiveSolverConfig false' '-smt_nonLinearArithmetic true' \
	$(if $(short), --short_output,)$(if $(rule), --rule $(rule),)$(if $(multi), --multi_assert_check,)
deploy      :; ./deploy.sh config="$(config)"
deploy-core :; ./deploy-core.sh
