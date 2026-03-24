# frozen_string_literal: true

# spec/support/shared_examples.rb
# 共享测试示例 - 减少重复代码

# ============================================
# 模型验证相关
# ============================================

# 验证必填字段
shared_examples 'validates presence of' do |field|
  it "requires #{field}" do
    subject.send("#{field}=", nil)
    expect(subject).not_to be_valid
    expect(subject.errors[field]).to be_present
  end
end

# 验证唯一性
shared_examples 'validates uniqueness of' do |field|
  it "requires unique #{field}" do
    existing = create(described_class.name.underscore.to_sym)
    subject.send("#{field}=", existing.send(field))
    expect(subject).not_to be_valid
    expect(subject.errors[field]).to include('has already been taken')
  end
end

# 验证数值范围
shared_examples 'validates numericality of' do |field, options = {}|
  it "validates #{field} is a number" do
    subject.send("#{field}=", 'not_a_number')
    expect(subject).not_to be_valid
  end

  if options[:greater_than_or_equal_to]
    it "validates #{field} >= #{options[:greater_than_or_equal_to]}" do
      subject.send("#{field}=", options[:greater_than_or_equal_to] - 1)
      expect(subject).not_to be_valid
    end
  end
end

# ============================================
# API 响应相关
# ============================================

# 未认证请求返回 401
shared_examples 'requires authentication' do
  context 'without authentication' do
    it 'returns 401 unauthorized' do
      expect(response).to have_http_status(:unauthorized)
    end
  end
end

# 返回 JSON 响应
shared_examples 'returns JSON response' do
  it 'returns JSON content type' do
    expect(response.content_type).to include('application/json')
  end
end

# 返回成功响应
shared_examples 'returns success response' do
  it 'returns 200 OK' do
    expect(response).to have_http_status(:ok)
  end

  it_behaves_like 'returns JSON response'
end

# 返回创建成功响应
shared_examples 'returns created response' do
  it 'returns 201 Created' do
    expect(response).to have_http_status(:created)
  end

  it_behaves_like 'returns JSON response'
end

# 返回 404 响应
shared_examples 'returns not found' do
  it 'returns 404 Not Found' do
    expect(response).to have_http_status(:not_found)
  end
end

# 返回 422 响应
shared_examples 'returns unprocessable entity' do
  it 'returns 422 Unprocessable Entity' do
    expect(response).to have_http_status(:unprocessable_entity)
  end
end

# 返回标准 API 响应结构
shared_examples 'returns standard API response' do
  it 'includes code field' do
    json = JSON.parse(response.body)
    expect(json).to have_key('code')
  end

  it 'includes message field' do
    json = JSON.parse(response.body)
    expect(json).to have_key('message')
  end
end

# ============================================
# 分页相关
# ============================================

shared_examples 'supports pagination' do
  it 'returns pagination metadata' do
    json = JSON.parse(response.body)
    expect(json['data']).to have_key('total')
    expect(json['data']).to have_key('page')
    expect(json['data']).to have_key('per_page')
  end
end

# ============================================
# Token ID 验证相关
# ============================================

# 验证结构化 Token ID 格式
shared_examples 'uses structured token ID' do
  it 'uses structured token ID format (not simple numbers)' do
    # 结构化 Token ID 应该是较大的数字 (0x10xxxx 格式)
    # 绝对不应该是简单的 1, 2, 3 等
    token_id = subject.token_id.to_i
    expect(token_id).to be > 1_000_000, 'Token ID should be structured, not a simple number like 1, 2, 3'
  end
end

# ============================================
# 数据库操作相关
# ============================================

# 创建记录
shared_examples 'creates a record' do |model_class|
  it "creates a new #{model_class}" do
    expect { subject }.to change(model_class, :count).by(1)
  end
end

# 不创建记录
shared_examples 'does not create a record' do |model_class|
  it "does not create a new #{model_class}" do
    expect { subject }.not_to change(model_class, :count)
  end
end

# 删除记录
shared_examples 'deletes a record' do |model_class|
  it "deletes the #{model_class}" do
    expect { subject }.to change(model_class, :count).by(-1)
  end
end

# ============================================
# 认证上下文
# ============================================

# 已认证用户上下文
shared_context 'with authenticated user' do
  let(:user) { create(:accounts_user) }
  let(:auth_headers) do
    token = JWT.encode({ address: user.address, exp: 24.hours.from_now.to_i }, Rails.application.config.x.auth.jwt_secret)
    { 'Authorization' => "Bearer #{token}" }
  end

  before do
    # 如果使用 request spec，设置 headers
    request.headers.merge!(auth_headers) if defined?(request)
  end
end

# 管理员上下文
shared_context 'with admin user' do
  let(:admin_user) { create(:accounts_user, :admin) }
  let(:auth_headers) do
    token = JWT.encode({ address: admin_user.address, role: 'admin', exp: 24.hours.from_now.to_i }, Rails.application.config.x.auth.jwt_secret)
    { 'Authorization' => "Bearer #{token}" }
  end
end
