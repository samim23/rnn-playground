require 'torch'
require 'nn'
require 'nngraph'
require 'data_processing'
local model_utils = require 'model_utils'
package.path = package.path .. ";./network/?.lua"

s2s = {}

--[[ Arguments:
	gpu
	batch_size
	seq_len
	collect_often
	noclones	-- if true, gradients are calculated more slowly but much more memory-efficiently (default false)
	report_freq
	conv_verbose	-- if true, when conversing, if input symbol is unknown, declare so

	RNN_type	-- string, determines RNN type. options are 'LSTM', 'GRU', 'Vanilla'.

	training_mode	-- if 1, randomly samples minibatches from anywhere in text corpus (default)
			-- if 2, proceeds linearly through text corpus

	lr
	lambda
	gamma
	grad_clip
	clip_to

	pattern
	lower
	rawdata
	usemostcommon	-- use only the most common pattern-matching entries in rawdata as input symbols
	useNmostcommon  -- how many?

	layer_sizes
	peepholes	-- for LSTM networks
	nl_type		-- for Vanilla RNN networks
]]
function init(args)

	-- Verbosity
	s2s.report_freq = args.report_freq or 10
	s2s.conv_verbose = args.conv_verbose or false

	-- Computational
	s2s.gpu = args.gpu or -1
	if s2s.gpu >= 0 then
		require 'cutorch'
		require 'cunn'
	end
	s2s.batch_size = args.batch_size or 30
	s2s.seq_len = args.seq_len or 50
	s2s.collect_often = args.collect_often or false
	s2s.noclones = args.noclones or false

	-- RMSprop and clipping gradients
	s2s.lr = args.lr or 0.001		-- learning rate
	s2s.lambda = args.lambda or 1e-8
	s2s.gamma = args.gamma or 0.95
	s2s.grad_clip = args.grad_clip or true
	s2s.clip_to = args.clip_to or 5

	-- Training
	s2s.training_mode = args.training_mode or 1

	-- Data
	s2s.pattern = args.pattern or '.'
	s2s.lower = args.lower or false
	s2s.usemostcommon = args.usemostcommon or false
	s2s.useNmostcommon = args.useNmostcommon or 4500
	s2s.replace = args.replace or false
	s2s.wordopt = {usemostcommon = s2s.usemostcommon, useNmostcommon = s2s.useNmostcommon, replace = s2s.replace}
	s2s.filename = args.filename or 'input.txt'
	s2s.rawdata = args.rawdata or data(s2s.filename)
	print('Creating embedding/deembedding tables for characters in data...')
	s2s.embed, s2s.deembed, s2s.numkeys, s2s.numwords, s2s.tokenized, s2s.freq_data = data_processing(s2s.rawdata,s2s.pattern,s2s.lower,s2s.wordopt)
	s2s.numkeys = s2s.numkeys + 1 		-- for unknown character
	print('Finished making embed/deembed tables.') 
	print('Finished making embedded data.')
	print('Dictionary has this many keys in it: ',s2s.numkeys)

	-- Input mode things
	s2s.eye = torch.eye(s2s.numkeys)
	s2s.decoder = true
	s2s.rnn_input_size = s2s.numkeys

	-- Networks and parameters
	s2s.layer_sizes = args.layer_sizes or {128}
	s2s.peepholes = args.peepholes or false
	s2s.nl_type = args.nl_type or 'tanh'
	s2s.n_hidden = 0

	s2s.RNN_type = args.RNN_type or 'LSTM'

	-- Interpret RNN_type options and compute length of hidden state vector
	if s2s.RNN_type == 'LSTM' then
		print('Making LSTM...')
		for i=1,#s2s.layer_sizes do s2s.n_hidden = s2s.n_hidden + 2*s2s.layer_sizes[i] end
		require 'LSTM'
	elseif s2s.RNN_type == 'GRU' then
		print('Making GRU...')
		for i=1,#s2s.layer_sizes do s2s.n_hidden = s2s.n_hidden + s2s.layer_sizes[i] end
		require 'GRU'
	elseif s2s.RNN_type == 'Vanilla' then
		print('Making Vanilla RNN...')
		for i=1,#s2s.layer_sizes do s2s.n_hidden = s2s.n_hidden + s2s.layer_sizes[i] end
		require 'VanillaRNN'
	end

	-- Build RNN and make references to its parameters and gradient
	if args.RNN then
		s2s.RNN = args.RNN
	elseif s2s.RNN_type == 'LSTM' then
		s2s.RNN = LSTM(s2s.rnn_input_size,s2s.layer_sizes,{peepholes=s2s.peepholes,decoder=s2s.decoder,fgate_init=true})
	elseif s2s.RNN_type == 'GRU' then
		s2s.RNN = GRU(s2s.rnn_input_size,s2s.layer_sizes,{decoder=s2s.decoder})
	elseif s2s.RNN_type == 'Vanilla' then
		s2s.RNN = VanillaRNN(s2s.rnn_input_size,s2s.layer_sizes,{decoder=s2s.decoder,nl_type=s2s.nl_type})
	end
	if s2s.gpu >= 0 then s2s.RNN:cuda() end
	s2s.params, s2s.gradparams = s2s.RNN:getParameters()
	s2s.v = s2s.gradparams:clone():zero()
	print('RNN is done.')

	-- Make criterion
	print('Making criterion...')
	local criterion_input_1, criterion_input_2, criterion_out
	criterion_input_1 = nn.Identity()()
	criterion_input_2 = nn.Identity()()
	criterion_out = nn.ClassNLLCriterion()({nn.LogSoftMax()(criterion_input_1),criterion_input_2})
	s2s.criterion = nn.gModule({criterion_input_1,criterion_input_2},{criterion_out})
	if s2s.gpu >= 0 then s2s.criterion:cuda() end
	print('Criterion is done.')

	-- Make RNN/criterion clones, if applicable
	if not(s2s.noclones) then
		clones = {}
		print('Cloning RNN...')
		clones.RNN = model_utils.clone_many_times(s2s.RNN,s2s.seq_len)
		collectgarbage()
		print('Cloning criterion...')
		clones.criterion = model_utils.clone_many_times(s2s.criterion,s2s.seq_len)
		collectgarbage()
		print('Clones are done.')
	end
	
	if s2s.gpu >=0 then
		free,tot = cutorch.getMemoryUsage()
		print('Free fraction of memory remaining: ', free/tot)
	end
	print('Number of trainable parameters: ', s2s.params:nElement())

end


-- TRAINING

function grad_pass_with_clones()
	total_loss = 0
	for i=1,s2s.seq_len do
		clones.RNN[i]:forward({H[i],X[i]})
		if i < s2s.seq_len then H[i+1] = clones.RNN[i].output[1] end
		loss = clones.criterion[i]:forward({clones.RNN[i].output[2],Y[i]})
		total_loss = total_loss + loss[1]
	end
	if s2s.collect_often then collectgarbage() end

	local gradH
	for i=s2s.seq_len,1,-1 do
		clones.criterion[i]:backward({clones.RNN[i].output[2],Y[i]},{1})
		if i < s2s.seq_len then
			gradH = clones.RNN[i+1].gradInput[1]
		else
			gradH = torch.Tensor():typeAs(H[i]):resizeAs(H[i]):zero()
		end
		clones.RNN[i]:backward({H[i],X[i]},{gradH,clones.criterion[i].gradInput[1]})
		if s2s.collect_often then collectgarbage() end
	end
end

function grad_pass_no_clones()
	total_loss = 0

	outputs = {}
	-- fwd pass to get the outputs and hidden states
	for i=1,s2s.seq_len do
		s2s.RNN:forward({H[i],X[i]})
		if i < s2s.seq_len then H[i+1] = s2s.RNN.output[1] end
		outputs[i] = s2s.RNN.output[2]
	end
	if s2s.collect_often then collectgarbage() end

	gradInputs = {}
	-- bwd pass
	for i=s2s.seq_len,1,-1 do
		loss = s2s.criterion:forward({outputs[i],Y[i]})
		total_loss = total_loss + loss[1]
		s2s.criterion:backward({outputs[i],Y[i]},{1})
		s2s.RNN:forward({H[i],X[i]})
		if i < s2s.seq_len then
			s2s.RNN:backward({H[i],X[i]},{gradInputs[i], s2s.criterion.gradInput[1]})
		else
			s2s.RNN:backward({H[i],X[i]},{torch.Tensor():typeAs(H[i]):resizeAs(H[i]):zero(),s2s.criterion.gradInput[1]})
		end
		gradInputs[i-1] = s2s.RNN.gradInput[1]
	end
	if s2s.collect_often then collectgarbage() end
end

-- First index is time slice
-- Second is element-in-batch
function minibatch_loader()
	local i
	local preX,postX
	local I = torch.Tensor(s2s.seq_len,s2s.batch_size):zero():long()
	local X = torch.Tensor(s2s.seq_len,s2s.batch_size,s2s.rnn_input_size):zero()
	local Y = torch.Tensor(s2s.seq_len,s2s.batch_size):zero()
	local H = torch.Tensor(s2s.seq_len,s2s.batch_size,s2s.n_hidden):zero()

	if s2s.training_mode == 2 then
		if not(s2s.pos_in_text) then
			s2s.pos_in_text = 1
		end
	end

	for n=1,s2s.batch_size do
		if s2s.training_mode == 1 then
			i = torch.ceil(torch.uniform()*(s2s.numwords - s2s.seq_len))
		else
			i = s2s.pos_in_text
		end
		preX = s2s.tokenized[{{i,i + s2s.seq_len - 1}}]:long()
		postX = s2s.eye:index(1,preX)
		I[{{},{n}}]:copy(preX)
		X[{{},{n}}]:copy(postX)
		Y[{{},{n}}] = s2s.tokenized[{{i+1,i + s2s.seq_len}}]
		if s2s.training_mode == 2 then
			s2s.pos_in_text = s2s.pos_in_text + s2s.seq_len
			if s2s.pos_in_text > s2s.numwords - s2s.seq_len then
				s2s.pos_in_text = 1
			end
		end
	end

	if s2s.gpu >= 0 then
		X = X:float():cuda()
		Y = Y:float():cuda()
		H = H:float():cuda()
	end

	return X,Y,H,I
end


function train_network_one_step()
	X,Y,H,I = minibatch_loader()
	s2s.gradparams:zero()

	if s2s.noclones then
		grad_pass_no_clones()
	else
		grad_pass_with_clones()
	end

	-- Average over batch and sequence length
	s2s.gradparams:div(s2s.batch_size):div(s2s.seq_len)

	if s2s.grad_clip then
		s2s.gradparams:clamp(-s2s.clip_to, s2s.clip_to)
	end
	-- RMSprop:
	local grad = s2s.gradparams:clone()
	grad:pow(2):mul(1 - s2s.gamma)
	s2s.v:mul(s2s.gamma):add(grad)
	s2s.gradparams:cdiv(torch.sqrt(s2s.v):add(s2s.lambda))
	s2s.params:add(-s2s.lr,s2s.gradparams)

	collectgarbage()
end

function train_network_N_steps(N)
	running_total_loss = 0
	for n=1,N do
		train_network_one_step()
		if n==1 then init_error = total_loss/s2s.seq_len end
		if total_loss/s2s.seq_len > 3*init_error then
			print('Error is exploding. Current error: ', total_loss/s2s.seq_len)
			print('Terminating training here.')
			break
		end
		running_total_loss = running_total_loss + total_loss/s2s.seq_len
		if n % s2s.report_freq == 0 then 
			if s2s.training_mode == 1 then
				print('Average Error: ',running_total_loss/s2s.report_freq,'Num Steps: ',n)
			else
				print('Average Error: ',running_total_loss/s2s.report_freq,'Num Steps: ',n,' % thru text: ', round(100*s2s.pos_in_text/s2s.numwords))
			end 
			running_total_loss = 0
		end
	end
end

function round(x)
	return math.floor(x * 1000)/1000
end

-- SAMPLING

function tokenize_string(text)

	local splitstring = split_string(text,s2s.pattern,s2s.lower,s2s.wordopt)
	local numtokens = #splitstring
	local tokenized = torch.zeros(numtokens)
	for i=1,numtokens do
		tokenized[i] = s2s.embed[splitstring[i]] or s2s.numkeys
		if tokenized[i] == s2s.numkeys and s2s.conv_verbose then
			print('Machine Subconscious: I did not recognize the word ' .. splitstring[i] .. '.')
			print()
		end
	end

	return tokenized:long(), numtokens
end

function string_to_rnn_input(text)
	local tokenized, numtokens = tokenize_string(text)
	local X = torch.zeros(numtokens,s2s.rnn_input_size)
	X:copy(s2s.eye:index(1,tokenized))
	return X
end

function sample_from_network(args)
	local X, xcur, hcur
	local length = args.length
	local chatmode = args.chatmode or false
	local toscreen = args.toscreen or not(chatmode)
	local primetext = args.primetext
	sample_text = ''

	xcur = torch.Tensor(s2s.rnn_input_size):zero()
	hcur = args.hcur or torch.Tensor(s2s.n_hidden):zero()

	softmax = nn.SoftMax()
	if s2s.gpu >= 1 then
		xcur = xcur:float():cuda()
		hcur = hcur:float():cuda()
		softmax:cuda()
	end

	if not(primetext) then
		i = torch.ceil(torch.uniform()*s2s.numkeys)
		xcur[i] = 1
	else
		X = string_to_rnn_input(primetext)
		if s2s.gpu >=1 then
			X = X:cuda()
		end
		for n=1,X:size(1)-1 do
			s2s.RNN:forward({hcur,X[n]})
			hcur = s2s.RNN.output[1]
		end
		xcur = X[X:size(1)]
	end

	local function next_character(pred)
		local probs = softmax:forward(pred)
		if args.temperature then
			local logprobs = torch.log(probs)
			logprobs:div(args.temperature)
			probs = torch.exp(logprobs)
		end
		probs:div(torch.sum(probs))
		local next_char = torch.multinomial(probs:float(), 1):resize(1):float()
		local i = next_char[1]
		local next_text = s2s.deembed[i] or ''
		return i, next_text
	end

	local n = 1
	repeat
		s2s.RNN:forward({hcur,xcur})
		hcur = s2s.RNN.output[1]
		pred = s2s.RNN.output[2]
		i, next_text = next_character(pred)
		xcur:zero()
		xcur[i] = 1
		if s2s.pattern == 'word' then
			if not(i==s2s.numkeys) then
				sample_text = sample_text .. ' ' .. next_text
			end
		else
			sample_text = sample_text .. next_text
		end
		if length then 
			end_condition = (n==length)
			n = n + 1
		else
			end_condition = (next_text == '\n')	-- output character is unknown/EOS
		end
	until end_condition

	if toscreen then
		print('Sample text: ',sample_text)
	end
	if chatmode then
		return sample_text, hcur
	else
		return sample_text
	end
end

function test_conv(temperature)
	local user_input
	local args
	local hcur = torch.Tensor(s2s.n_hidden):zero()
	repeat
		user_input = io.read()
		io.write('\n')
		io.flush()
		if not(user_input) then
			user_input = ' '
		end
		args = {hcur = hcur, chatmode=true, primetext = user_input .. '\n', temperature = temperature}
		--if length then args.length = length end
		machine_output, hcur = sample_from_network(args)
		io.write('Machine: ' .. machine_output .. '\n')
		io.flush()
	until user_input=="quit"
end

-- SAVING AND LOADING AND CHECKING MEMORY

function memory()
	free,tot = cutorch.getMemoryUsage()
	print(free/tot)
end

function load(filename,gpu)
	-- check some requirements before loading
	local gpu = gpu or -1
	if gpu>=0 then
		require 'cutorch'
		require 'cunn'
	end
	require 'LSTM'
	require 'GRU'
	require 'VanillaRNN'

	T = torch.load(filename)
	s2s = T.s2s
	init(s2s)
end

function loadFromOptions(filename)
	T = torch.load(filename)
	s2s = T.s2s
	s2s.RNN = nil
end

function save(filename)
	torch.save(filename .. '.t7',{s2s = s2s})
end
