classdef mlnn
% MLNN: A Multi-Layer Neural Network object

% TO DO:	CROSS VALIDATION
%  			TEST ERROR
%			VISUALIZATION
%			ASESS NETWORK
%			TEST ON DATA
%			TEST CLASSIFICATION

properties
	class = 'mlnn';
	X = [];					% NETWORK DATA
	nLayers = [];			% # OF WEIGHT LAYERS
	layers = {};			% LAYER STRUCTS
	nInputs = [];			% # OF INPUTS TO NETWORK
	nOutputs = [];			% # OF NETWORK OUTPUTS
	netOutput = [];			% CURRENT OUTPUT OF THE NETWORK
	costFun = 'mse';		% COST FUNCTION
	J = [];					% CURRENT COST 
	dJ = [];				% CURRENT COST GRADIENT
	nXVal = .2;				% PORTION OF DATA FOR XVAL.
	trainTime = Inf;		% TRAINING DURATION
	nEpoch = 100;			% TOTAL NUMBER OF TRAINING EPOCHS
	epoch = 1;				% CURRENT NUMBER OF EPOCH
	batchError = [];		% TRAINING ERROR FOR BATCHES
	trainError = [];		% TRAINING ERROR HISTORY
	xValError = [];			% XVALI	DATION EROR HISTORY
	bestxValError = Inf		% TRACK BEST NETWORK ERROR
	bestNet = [];			% STORAGE FOR BEST NETWORK
	batchSize = 100;		% SIZE OF BATCHES
	trainBatches = [];		% BATCH INDICES
	xValIdx = [];			% XVAL. DATA INDICES
	crossValidating=0;		% ARE WE CROSSVALIDATING?
	saveEvery = 500;		% SAVE PROGRESS EVERY 
	saveDir = './mlnnSave';	% WHERE TO SAVE PROGRESS
	stopEarly = 5;			% # OF EARLY STOP EPOCHS (XVAL ERROR INCREASES)
	stopEarlyCnt = 0;		% EARLY STOPPING CRITERION COUNTER
	visFun=@visNNLearning;	% VISUALIZATION FUNCTION HANDLE
	preWhiten = 0;			% SPHERE NETWORK INPUTS
	beginTraining = 1;		% TRAIN AFTER INITIALIZATION
	verbose = 500;
	task = [];
	auxInput = [];
	useGPU = 1;
	gpuDevice = [];
end % END PROPERTIES

methods
	function self = mlnn(args,X,targs)
		if notDefined('args')
			args = self.setupArgs({});
		end

		% CONSTRUCTOR FUNCTION
		if nargin == 3
			nIn = size(X,2); nOut = size(targs,2);
		end
		if nargin == 2, error('wrong number of inputs'); end
		if nargin == 1
			try
				load('defaultData.mat','X','targets');
				nIn = size(X,1); nOut = numel(targets);
			catch
				error('could not retrieve data, please provide data or input and output dimensions');
			end
		end
		if ~nargin, return; end % RETURN DEFAULT OBJECT
		self = self.init(args,nIn,nOut);
		self = self.makeBatches(X);
		if self.beginTraining, self = self.train(X,targs);end
	end

	% DISPLAY PROPERTIES AND METHODS
	function print(self)
		properties(self)
		methods(self)
	end

	function self = init(self,args,nIn,nOut)
		self.nInputs = nIn;
		self.nOutputs = nOut;
		nHid = [];
		
		% PARSE ARGUMENTS/OPTIONS
		if iscell(args)
			nHidIdx = find(strcmp(args,'nHid'));
		
			if ~isempty(nHidIdx)
				nHid = args{nHidIdx+1};
			else
				error('could not parse the number of hidden units from cell array or argments');
			end
		else
			nHid = args.nOut;
		end
	
		nHid = [nHid,nOut];
		self.nLayers = numel(nHid); % LAYERS DEFINED IN TERMS
									% OF # WEIGHTS LAYERS

		self.layers{1}.nIn = nIn;
		self.layers{1}.nOut = nHid(1);

		for iL = 2:self.nLayers
			self.layers{iL}.nIn = self.layers{iL-1}.nOut;
			self.layers{iL}.nOut = nHid(iL);
		end

		[args,self] = self.setupArgs(args,nHid);
		self.trainError = zeros(self.nEpoch,1);
		self.xValError = self.trainError;
		
		for iL = 1:self.nLayers
			if iL == self.nLayers &  (sum(strcmp(self.costFun,{'xEntropy','negLogLike'}))>0 || strcmp(self.task,'regression'))
				self.layers{iL}.actFun = 'linear'
			else
				self.layers{iL}.actFun = args.actFun{iL};
			end

			% WEIGHTS AND WEIGHT GRADIENTS
			self.layers{iL}.W = randn(self.layers{iL}.nIn,self.layers{iL}.nOut)/sqrt(self.layers{iL}.nIn);
			self.layers{iL}.dW = self.layers{iL}.W;
			
			% BIAS AND BIAS GRADIENTS
			self.layers{iL}.bias = zeros(self.layers{iL}.nOut,1);
			self.layers{iL}.dBias = self.layers{iL}.bias;

			% LEARNING RATE
			self.layers{iL}.lambda = args.lambda(iL);
			self.layers{iL}.dLambda = args.dLambda(iL);

			% WEIGHT DECAY
			self.layers{iL}.weightCost = 0;
			self.layers{iL}.weightDecay = args.weightDecay(iL);

			% MOMENTUM
			self.layers{iL}.momentum = args.momentum(iL);
		end
		if self.useGPU
			self = gpuDistribute(self);
		end		
	end

	function self = train(self,X,targs); % MAIN LEARNING ALGORITHM
		if self.preWhiten
			self.X = self.whitenData(X);
			clear X;
		end
		tic; cnt = 1;
		nBatches = numel(self.trainBatches);
		while 1
			if self.verbose, self.printProgress('epoch'); end

			% LOOP OVER MINIBATCHES
			for iB = 1:nBatches
				batchIdx = self.trainBatches{iB};
				netInput = self.X(batchIdx,:);
				% PROPAGATE SIGNALS UP...
				self = self.prop(netInput);
				% CALCULATE COST...
				[self.J,self.dJ] = self.cost(targs(batchIdx,:));
				% BACKPROPAGATE ERRORS DOWN...
				self = self.backprop(netInput);
				% APPLY WEIGHT GRADIENTS...
				self = self.updateParams();
				% ASSESS ERROR FOR CURRENT BATCH
				self.batchError(batchIdx) = self.J;
				% DISPLAY
				if self.verbose & ~mod(cnt,self.verbose);
					self.visLearning;
				end
				cnt = cnt+1;
			end

			% FIND MEAN SQUAREED ERROR OVER ALL TRAINING POINTS
			self.trainError(self.epoch) = mean(self.batchError);
			
			% CROSS VALIDATE, UPDATE EARLY STOPPING CRITERION &
			% STORE BEST NETWORK
			if self.verbose,
				self.printProgress('trainError');
				self.printProgress('time');
			end
			

			if ~isempty(self.xValIdx)
				self = self.crossValidate(self.X,targs);
				self = self.assessNet;
				if self.verbose, self.printProgress('xValError');end
			end


			if (self.epoch >= self.nEpoch) || ...
			(self.stopEarlyCnt >= self.stopEarly),
				 break;
			end
			if ~mod(self.epoch,self.saveEvery), self.save; end
			self.epoch = self.epoch + 1;
		end
		if self.useGPU
			self = gpuGather(self);
			reset(self.gpuDevice);
			self.gpuDevice = [];
		end
		self.trainTime = toc;
	end


	% FORWARD PROPAGATION THROUGH NETWORK
	function self = prop(self,layerIn)

		for iL = 1:self.nLayers
			W = self.layers{iL}.W;
			bias = self.layers{iL}.bias;

			preAct = bsxfun(@plus,layerIn*W,bias');

			switch self.layers{iL}.actFun
				case 'linear'
					self.layers{iL}.output = preAct;
				case {'sigmoid','logistic'}
					self.layers{iL}.output = sigmoid(preAct);
				case {'tanh'}
					self.layers{iL}.output = tanh(preAct);
				case {'softplus'}
					self.layers{iL}.output = sofplus(preAct);
			end

			if iL == self.nLayers
				self.netOutput = self.layers{iL}.output;
			else
				layerIn = self.layers{iL}.output;
			end
		end

		if ~self.crossValidating
			% TAKE CARE OF WEIGHT DECAY
			for iL = 1:self.nLayers
				if self.layers{iL}.weightDecay > 0  % L2 DECAY
					self.layers{iL}.weightCost =.5*sum(W(:).^2)*self.layers{iL}.weightDecay;

				elseif self.layers{iL}.weightDecay < 0 % L1 DECAY
					self.layers{iL}.weightCost = sum(abs(W(:)))*abs(self.layers{iL}.weightDecay);

				elseif self.layers{iL}.weightDecay == 0  % NO DECAY
					self.layers{iL}.weightCost = 0;
				end
			end
		end
	end

	% EVALUATE COST FUNCTION AND GRADIENT
	function [J,dJ] = cost(self,targs,costFun)
		if notDefined('costFun'), costFun = self.costFun; end
		layers = [self.layers{:}];
		netOut = self.netOutput;
		[nObs,nTargs] = size(netOut);
		weightDecayCost = sum([layers.weightCost]);

		switch costFun
			case 'mse' 		% MEAN SQUARED ERROR
				delta = netOut - targs;
				J =  0.5*sum(delta.^2,2) + weightDecayCost;
				dJ = delta/nObs;

			case 'negLogLike' % NEGATIVE LOG LIKELIHOOD
				class = softMax(netOut);
				J = sum(-log(class).*targs)+weightDecayCost;
				dJ = (-targs + class)/nObs;

			case 'xEntropy'	% CROSS ENTROPY
				J = -sum(netOut.*targs - log(1 + exp(netOut)),2);

				% (NUMERICAL STABILITY)
				if any(netOut>20)
					J(netOut>20) = -sum(netOut(netOut>20).*targs(netOut>20) - netOut(netOut>20),2);
				end
				
				J = J + weightDecayCost;
				dJ = -(targs - sigmoid(netOut))/nObs;

			case 'classError' % (ONLY FOR) CLASSIFICATION ERROR
				[foo,class]=max(netOut,[],2);
				J = class ~= sum(bsxfun(@times,targs,(1:nTargs)),2);
				dJ = 'No Gradient Available';
		end
	end

	 % BACKPROPAGATE ERRORS
	function self = backprop(self,netInput)
		gradIn = self.dJ;
		for iL = self.nLayers:-1:1

			% UNPACK WEIGHTS
			W = self.layers{iL}.W;
			if iL == self.nLayers
				layerOut = self.layers{iL}.output;
			else
				layerOut = layerIn;
			end

			if iL == 1
				layerIn = netInput;
			else
				layerIn = self.layers{iL-1}.output;
			end

			% ACTIVATION FUNCTION GRADIENTS
			switch self.layers{iL}.actFun
				case {'sigmoid','logistic'}
					dAct = layerOut.*(1-layerOut);
				case {'linear'}
					dAct = ones(size(gradIn));
				case {'tanh'}
					dAct = 1 - layerOut.^2;
				case {'softplus'}
					dAct = sigmoid(layerIn);
			end
			gradOut = gradIn.*dAct;

			% WEIGHT DECAY GRADIENTS
			if self.layers{iL}.weightDecay > 0 % L2 DECAY
				dWeightDecay = self.layers{iL}.weightDecay*W;

			elseif self.layers{iL}.weightDecay < 0 % L1 DECAY
				dWeightDecay = abs(self.layers{iL}.weightDecay)*sign(W);

			elseif self.layers{iL}.weightCost == 0 % NO DECAY
				dWeightDecay = 0;
			end


			% UPDATE WEIGHT GRADIENTS
			dW = layerIn'*gradOut + dWeightDecay;
			db = sum(gradOut);
			p = self.layers{iL}.momentum;
			
			self.layers{iL}.dW = p*self.layers{iL}.dW + (1-p)*dW;
			self.layers{iL}.dBias = p*self.layers{iL}.dBias + (1-p)*db';

			if iL > 1
				gradIn = gradOut*W.';
			end
		end
	end

	function self = updateParams(self)
		for iL = self.nLayers:-1:1
			% VARIABLE LEARNING RATE
			lambda = self.layers{iL}.lambda/(1 + self.layers{iL}.dLambda);

			% UNPACK 
			dW = self.layers{iL}.dW;
			db = self.layers{iL}.dBias;
			W = self.layers{iL}.W;
			bias = self.layers{iL}.bias;

			% UPDATE
			W = W - lambda*dW;
			bias = bias - lambda*db;

			% REPACK
			self.layers{iL}.W = W;
			self.layers{iL}.bias = bias;
			self.layers{iL}.lambda = lambda;
		end
	end

	% ASSES PREDICTIONS/ERROS ON TEST DATA
	function [pred,errors] = test(self,X,targs,costFun)
		if notDefined('costFun')
			costFun = self.costFun;
		end
		self = self.prop(X);
		pred = self.netOutput;
		errors = self.cost(targs,costFun);
		self = [];
	end

	% CREATE MINIBATCHES
	function self = makeBatches(self,X);
		nObs = size(X,1);
		if self.nXVal < 1
			nVal = round(self.nXVal*nObs);
		else
			nVal = self.nXVal;
		end
		xValIdx = nObs-nVal+1:nObs;
		nObs = nObs - nVal;
		nBatches = ceil(nObs/self.batchSize);
		self.batchError = zeros(nObs,1);
		idx = round(linspace(1,nObs+1,nBatches+1));
		for iB = 1:nBatches
			if iB == nBatches
				batchIdx{iB} = idx(iB):nObs;
			else
				batchIdx{iB} = idx(iB):idx(iB+1)-1;
			end
		end
		self.trainBatches = batchIdx;
		self.batchError = zeros(nObs,1);

		nxBatches = ceil(nVal/self.batchSize);
		xValIdx = round(linspace(xValIdx(1),xValIdx(end)+1,nxBatches));

		for iB = 1:nxBatches-1
			if iB == nxBatches
				xBatchIdx{iB} = xValIdx(iB):nVal;
			else
				xBatchIdx{iB} = xValIdx(iB):xValIdx(iB+1)-1;
			end
		end
		self.xValIdx = xBatchIdx;
	end

	% VISUALIZATIONS
	function visLearning(self)
		try
			self.visFun(self); drawnow;
		catch 
			clf
			plot(self.trainError(1:self.epoch-1));
			title('Output Error');
			drawnow
		end
	end

	% SAVE NETWORK
	function save(self);
		if self.verbose, self.printProgress('save'); end
		
		if ~isdir(self.saveDir)
			mkdir(self.saveDir);
		end
		epoch = self.epoch;
		fileName = fullfile(self.saveDir,sprintf('mlnn-%d.mat',epoch));
		net = self.bestNet;
		save(fileName,'net');
	end

	% ACCUMULATE ERROR FOR EACH BATCH
	function self = accumTrainError(self,batchIdx)
		self.batchError(self.trainBatches(batchIdx))=self.J;
	end

	% VERBOSE
	function printProgress(self,type)
		switch type
		case 'epoch'
			fprintf('Epoch: %i/%i',self.epoch,self.nEpoch);
		case 'trainError'
			fprintf('\t%s: %2.3f',self.costFun,self.trainError(self.epoch));
		case 'time'
			fprintf('\tTime: %g\n', toc);
		case 'xValError'
			if ~self.stopEarlyCnt
				fprintf('CrossValidation Error:  %g (best net) \n',self.xValError(self.epoch));
			else
				fprintf('CrossValidation Error:  %g\n',self.xValError(self.epoch));
			end
		case 'save'
			fprintf('\nSaving...\n\n');
		end
	end

	% CROSSVALIDATE
	function self = crossValidate(self,X,targs)
		self.crossValidating = 1;
		if strcmp(self.task, 'classification')
			costFun = 'classError';
		else
			costFun = [];
		end		
		xValError = 0;
		for iB = 1:numel(self.xValIdx)
			idx = self.xValIdx{iB};
			[~,tmpError]=self.test(X(idx,:),targs(idx,:),costFun);
			xValError = xValError + mean(tmpError);
		end
		self.xValError(self.epoch) = xValError/iB;
		self.crossValidating = 0;
	end

	% ASSESS THE CURRENT PARAMETERS AND STORE NET, IF NECESSARY
	function self = assessNet(self)
		if self.epoch > 1
			if self.xValError(self.epoch) < self.bestxValError
				self.bestNet = self.layers;
				self.stopEarlyCnt = 0;
			else
				self.stopEarly = self.stopEarly + 1;
			end
		else
			self.bestNet = self.layers;% STORE FIRST NET BY DEFAULT
		end
		
	end
	
	% WHITEN VIA ZCA TRANSFORM
	function [wX] = whitenData(self,X)
		fprintf('pre-whitening data...');
		mu = mean(X);
		wX = bsxfun(@minus,X,mu);
		wX = X/sqrtm(cov(X));
		fprintf('done\n');
	end

	% FORMAT ARGUMENTS
	function [args0,self] = setupArgs(self,args,nHid);

		% ALLOW FOR CELL-INPUT ARGUMENTS
		if iscell(args);
			c = args(2:2:end);
			f = args(1:2:end);
			args = cell2struct(c,f,2);
		end

		% GLOBAL ARGUMENTS
		if isfield(args,'costFun'); self.visFun = args.costFun; end;
		if isfield(args,'nXVal'); self.nXVal = args.nXVal; end;
		if isfield(args,'nEpoch'); self.nEpoch = args.nEpoch; end;
		if isfield(args,'batchSize'); self.batchSize = args.batchSize; end;
		if isfield(args,'saveEvery'); self.saveEvery = args.saveEvery; end;
		if isfield(args,'saveDir'); self.saveDir = args.saveDir; end;
		if isfield(args,'stopEarly'); self.stopEarly = args.stopEarly; end;
		if isfield(args,'visFun'); self.visFun = args.visFun; end;
		if isfield(args,'preWhiten'); self.preWhiten = args.preWhiten; end;
		if isfield(args,'beginTraining'); self.beginTraining = args.beginTraining; end;
		if isfield(args,'verbose'); self.verbose = args.verbose; end;
		if isfield(args,'task'); self.task = args.task; end;
		if isfield(args,'auxInput');self.auxInput=args.auxInput; end;

		% NECESSARY LAYER-WISE ARGMUMENTS 
		args0 = struct('actFun','tanh', ...		% ACTIVATION FUNCTION
					   'nHid', 100, ...			% # OF HIDDEN UNITS
					   'lambda', .001, ...		% CURRENT LEARNING RATE
					   'dLambda',.0001, ...		% VARIABLE LEARNING RATE
					   'momentum', .9, ...		% GRADIENT MOMENTUM
					   'weightDecay',1e-5);		% REGULARIZATION

		% LOOP OVER NECESSARY ARGUMENTS AND
		% LOOK FOR POSSIBLE REPLACEMENTS IN args
		f0 = fields(args0);
		f = fields(args);
		for iA = 1:numel(f0)
			idx = find(strcmp(f0{iA},f));
			if ~isempty(idx)
				vals = args.(f0{iA});
			else
				vals = args0.(f0{iA});
			end

			if ~isnumeric(vals) && ~iscell(vals)
				vals = {vals};
			end
			diff = numel(nHid) - numel(vals);
			if diff > 0
				vals = [vals,repmat(vals(end),1,diff)];
			end
			args0.(f0{iA}) = vals;
		end
	end
end % END METHODS
end % END CLASSDEF