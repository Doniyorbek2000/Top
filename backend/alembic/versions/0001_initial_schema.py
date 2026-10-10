"""initial schema

Revision ID: 0001
Revises: 
Create Date: 2026-10-10 15:18:33.478396

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

# revision identifiers, used by Alembic.
revision: str = '0001'
down_revision: Union[str, Sequence[str], None] = None
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    """Upgrade schema."""
    op.execute("CREATE EXTENSION IF NOT EXISTS pg_trgm")
    op.create_table('users',
    sa.Column('id', sa.BigInteger(), nullable=False),
    sa.Column('phone', sa.String(length=20), nullable=True),
    sa.Column('username', sa.String(length=32), nullable=True),
    sa.Column('first_name', sa.String(length=64), nullable=False),
    sa.Column('last_name', sa.String(length=64), nullable=False),
    sa.Column('bio', sa.String(length=140), nullable=False),
    sa.Column('avatar_media_id', sa.BigInteger(), nullable=True),
    sa.Column('is_bot', sa.Boolean(), nullable=False),
    sa.Column('last_seen_at', sa.DateTime(timezone=True), nullable=True),
    sa.Column('last_seen_visibility', sa.Enum('everybody', 'contacts', 'nobody', name='visibility'), nullable=False),
    sa.Column('phone_visibility', postgresql.ENUM('everybody', 'contacts', 'nobody', name='visibility', create_type=False), nullable=False),
    sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.PrimaryKeyConstraint('id'),
    sa.UniqueConstraint('phone')
    )
    op.create_index('ix_users_name_trgm', 'users', ['first_name', 'last_name'], unique=False, postgresql_using='gin', postgresql_ops={'first_name': 'gin_trgm_ops', 'last_name': 'gin_trgm_ops'})
    op.create_index('uq_users_username_lower', 'users', [sa.literal_column('lower(username)')], unique=True, postgresql_where=sa.text('username IS NOT NULL'))
    op.create_table('auth_sessions',
    sa.Column('id', sa.BigInteger(), nullable=False),
    sa.Column('user_id', sa.BigInteger(), nullable=False),
    sa.Column('refresh_token_hash', sa.String(length=64), nullable=False),
    sa.Column('device_name', sa.String(length=128), nullable=False),
    sa.Column('platform', sa.String(length=32), nullable=False),
    sa.Column('app_version', sa.String(length=32), nullable=False),
    sa.Column('ip', sa.String(length=64), nullable=False),
    sa.Column('push_token', sa.String(length=512), nullable=True),
    sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.Column('last_active_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.ForeignKeyConstraint(['user_id'], ['users.id'], ondelete='CASCADE'),
    sa.PrimaryKeyConstraint('id'),
    sa.UniqueConstraint('refresh_token_hash')
    )
    op.create_index(op.f('ix_auth_sessions_user_id'), 'auth_sessions', ['user_id'], unique=False)
    op.create_table('blocks',
    sa.Column('owner_id', sa.BigInteger(), nullable=False),
    sa.Column('blocked_id', sa.BigInteger(), nullable=False),
    sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.ForeignKeyConstraint(['blocked_id'], ['users.id'], ondelete='CASCADE'),
    sa.ForeignKeyConstraint(['owner_id'], ['users.id'], ondelete='CASCADE'),
    sa.PrimaryKeyConstraint('owner_id', 'blocked_id')
    )
    op.create_table('chat_folders',
    sa.Column('id', sa.BigInteger(), nullable=False),
    sa.Column('owner_id', sa.BigInteger(), nullable=False),
    sa.Column('title', sa.String(length=32), nullable=False),
    sa.Column('emoji', sa.String(length=16), nullable=False),
    sa.Column('position', sa.Integer(), nullable=False),
    sa.Column('include_types', postgresql.ARRAY(sa.String(length=16)), nullable=False),
    sa.Column('include_chat_ids', postgresql.ARRAY(sa.BigInteger()), nullable=False),
    sa.Column('exclude_chat_ids', postgresql.ARRAY(sa.BigInteger()), nullable=False),
    sa.Column('exclude_muted', sa.Boolean(), nullable=False),
    sa.Column('exclude_read', sa.Boolean(), nullable=False),
    sa.Column('exclude_archived', sa.Boolean(), nullable=False),
    sa.ForeignKeyConstraint(['owner_id'], ['users.id'], ondelete='CASCADE'),
    sa.PrimaryKeyConstraint('id')
    )
    op.create_index(op.f('ix_chat_folders_owner_id'), 'chat_folders', ['owner_id'], unique=False)
    op.create_table('contacts',
    sa.Column('owner_id', sa.BigInteger(), nullable=False),
    sa.Column('contact_id', sa.BigInteger(), nullable=False),
    sa.Column('first_name', sa.String(length=64), nullable=False),
    sa.Column('last_name', sa.String(length=64), nullable=False),
    sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.ForeignKeyConstraint(['contact_id'], ['users.id'], ondelete='CASCADE'),
    sa.ForeignKeyConstraint(['owner_id'], ['users.id'], ondelete='CASCADE'),
    sa.PrimaryKeyConstraint('owner_id', 'contact_id')
    )
    op.create_table('media',
    sa.Column('id', sa.BigInteger(), nullable=False),
    sa.Column('owner_id', sa.BigInteger(), nullable=False),
    sa.Column('kind', sa.String(length=16), nullable=False),
    sa.Column('mime_type', sa.String(length=128), nullable=False),
    sa.Column('file_name', sa.String(length=255), nullable=False),
    sa.Column('size', sa.BigInteger(), nullable=False),
    sa.Column('storage_key', sa.String(length=255), nullable=False),
    sa.Column('thumb_key', sa.String(length=255), nullable=True),
    sa.Column('width', sa.Integer(), nullable=True),
    sa.Column('height', sa.Integer(), nullable=True),
    sa.Column('duration_ms', sa.Integer(), nullable=True),
    sa.Column('waveform', postgresql.ARRAY(sa.Integer()), nullable=True),
    sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.ForeignKeyConstraint(['owner_id'], ['users.id'], ondelete='CASCADE'),
    sa.PrimaryKeyConstraint('id'),
    sa.UniqueConstraint('storage_key')
    )
    op.create_index(op.f('ix_media_owner_id'), 'media', ['owner_id'], unique=False)
    op.create_foreign_key('fk_users_avatar_media_id', 'users', 'media', ['avatar_media_id'], ['id'], ondelete='SET NULL')
    op.create_table('chats',
    sa.Column('id', sa.BigInteger(), nullable=False),
    sa.Column('type', sa.Enum('private', 'group', 'channel', 'saved', name='chat_type'), nullable=False),
    sa.Column('title', sa.String(length=128), nullable=False),
    sa.Column('description', sa.String(length=255), nullable=False),
    sa.Column('username', sa.String(length=32), nullable=True),
    sa.Column('avatar_media_id', sa.BigInteger(), nullable=True),
    sa.Column('invite_hash', sa.String(length=32), nullable=True),
    sa.Column('private_key', sa.String(length=64), nullable=True),
    sa.Column('created_by', sa.BigInteger(), nullable=True),
    sa.Column('pinned_message_id', sa.BigInteger(), nullable=True),
    sa.Column('last_message_id', sa.BigInteger(), nullable=True),
    sa.Column('members_can_send', sa.Boolean(), nullable=False),
    sa.Column('slow_mode_seconds', sa.Integer(), nullable=False),
    sa.Column('member_count', sa.Integer(), nullable=False),
    sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.Column('updated_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.ForeignKeyConstraint(['avatar_media_id'], ['media.id'], ondelete='SET NULL'),
    sa.ForeignKeyConstraint(['created_by'], ['users.id'], ondelete='SET NULL'),
    sa.PrimaryKeyConstraint('id'),
    sa.UniqueConstraint('invite_hash'),
    sa.UniqueConstraint('private_key')
    )
    op.create_index('ix_chats_title_trgm', 'chats', ['title'], unique=False, postgresql_using='gin', postgresql_ops={'title': 'gin_trgm_ops'})
    op.create_index('uq_chats_username_lower', 'chats', [sa.literal_column('lower(username)')], unique=True, postgresql_where=sa.text('username IS NOT NULL'))
    op.create_table('chat_members',
    sa.Column('chat_id', sa.BigInteger(), nullable=False),
    sa.Column('user_id', sa.BigInteger(), nullable=False),
    sa.Column('role', sa.Enum('owner', 'admin', 'member', name='member_role'), nullable=False),
    sa.Column('last_read_message_id', sa.BigInteger(), nullable=False),
    sa.Column('cleared_before_message_id', sa.BigInteger(), nullable=False),
    sa.Column('muted_until', sa.DateTime(timezone=True), nullable=True),
    sa.Column('is_pinned', sa.Boolean(), nullable=False),
    sa.Column('pin_order', sa.Integer(), nullable=False),
    sa.Column('is_archived', sa.Boolean(), nullable=False),
    sa.Column('draft', sa.Text(), nullable=False),
    sa.Column('joined_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.ForeignKeyConstraint(['chat_id'], ['chats.id'], ondelete='CASCADE'),
    sa.ForeignKeyConstraint(['user_id'], ['users.id'], ondelete='CASCADE'),
    sa.PrimaryKeyConstraint('chat_id', 'user_id')
    )
    op.create_index('ix_chat_members_user', 'chat_members', ['user_id'], unique=False)
    op.create_table('messages',
    sa.Column('id', sa.BigInteger(), nullable=False),
    sa.Column('chat_id', sa.BigInteger(), nullable=False),
    sa.Column('sender_id', sa.BigInteger(), nullable=True),
    sa.Column('client_id', sa.String(length=64), nullable=True),
    sa.Column('type', sa.Enum('text', 'photo', 'video', 'voice', 'audio', 'file', 'sticker', 'location', 'contact', 'poll', 'system', name='message_type'), nullable=False),
    sa.Column('text', sa.Text(), nullable=False),
    sa.Column('entities', postgresql.JSONB(astext_type=sa.Text()), nullable=True),
    sa.Column('media_id', sa.BigInteger(), nullable=True),
    sa.Column('extra', postgresql.JSONB(astext_type=sa.Text()), nullable=True),
    sa.Column('reply_to_id', sa.BigInteger(), nullable=True),
    sa.Column('forward_from_user_id', sa.BigInteger(), nullable=True),
    sa.Column('forward_from_chat_id', sa.BigInteger(), nullable=True),
    sa.Column('forward_from_message_id', sa.BigInteger(), nullable=True),
    sa.Column('forward_sender_name', sa.String(length=128), nullable=True),
    sa.Column('views', sa.Integer(), nullable=False),
    sa.Column('is_deleted', sa.Boolean(), nullable=False),
    sa.Column('edited_at', sa.DateTime(timezone=True), nullable=True),
    sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.ForeignKeyConstraint(['chat_id'], ['chats.id'], ondelete='CASCADE'),
    sa.ForeignKeyConstraint(['forward_from_chat_id'], ['chats.id'], ondelete='SET NULL'),
    sa.ForeignKeyConstraint(['forward_from_user_id'], ['users.id'], ondelete='SET NULL'),
    sa.ForeignKeyConstraint(['media_id'], ['media.id'], ondelete='SET NULL'),
    sa.ForeignKeyConstraint(['sender_id'], ['users.id'], ondelete='SET NULL'),
    sa.PrimaryKeyConstraint('id'),
    sa.UniqueConstraint('sender_id', 'client_id', name='uq_messages_sender_client')
    )
    op.create_index('ix_messages_chat_id_id', 'messages', ['chat_id', 'id'], unique=False)
    op.create_index('ix_messages_text_trgm', 'messages', ['text'], unique=False, postgresql_using='gin', postgresql_ops={'text': 'gin_trgm_ops'})
    op.create_table('hidden_messages',
    sa.Column('user_id', sa.BigInteger(), nullable=False),
    sa.Column('message_id', sa.BigInteger(), nullable=False),
    sa.ForeignKeyConstraint(['message_id'], ['messages.id'], ondelete='CASCADE'),
    sa.ForeignKeyConstraint(['user_id'], ['users.id'], ondelete='CASCADE'),
    sa.PrimaryKeyConstraint('user_id', 'message_id')
    )
    op.create_table('poll_votes',
    sa.Column('message_id', sa.BigInteger(), nullable=False),
    sa.Column('user_id', sa.BigInteger(), nullable=False),
    sa.Column('option_index', sa.Integer(), nullable=False),
    sa.ForeignKeyConstraint(['message_id'], ['messages.id'], ondelete='CASCADE'),
    sa.ForeignKeyConstraint(['user_id'], ['users.id'], ondelete='CASCADE'),
    sa.PrimaryKeyConstraint('message_id', 'user_id', 'option_index')
    )
    op.create_table('reactions',
    sa.Column('message_id', sa.BigInteger(), nullable=False),
    sa.Column('user_id', sa.BigInteger(), nullable=False),
    sa.Column('emoji', sa.String(length=16), nullable=False),
    sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    sa.ForeignKeyConstraint(['message_id'], ['messages.id'], ondelete='CASCADE'),
    sa.ForeignKeyConstraint(['user_id'], ['users.id'], ondelete='CASCADE'),
    sa.PrimaryKeyConstraint('message_id', 'user_id', 'emoji')
    )


def downgrade() -> None:
    """Downgrade schema."""
    op.drop_constraint('fk_users_avatar_media_id', 'users', type_='foreignkey')
    op.drop_table('reactions')
    op.drop_table('poll_votes')
    op.drop_table('hidden_messages')
    op.drop_index('ix_messages_text_trgm', table_name='messages', postgresql_using='gin', postgresql_ops={'text': 'gin_trgm_ops'})
    op.drop_index('ix_messages_chat_id_id', table_name='messages')
    op.drop_table('messages')
    op.drop_index('ix_chat_members_user', table_name='chat_members')
    op.drop_table('chat_members')
    op.drop_index('uq_chats_username_lower', table_name='chats', postgresql_where=sa.text('username IS NOT NULL'))
    op.drop_index('ix_chats_title_trgm', table_name='chats', postgresql_using='gin', postgresql_ops={'title': 'gin_trgm_ops'})
    op.drop_table('chats')
    op.drop_index(op.f('ix_media_owner_id'), table_name='media')
    op.drop_table('media')
    op.drop_table('contacts')
    op.drop_index(op.f('ix_chat_folders_owner_id'), table_name='chat_folders')
    op.drop_table('chat_folders')
    op.drop_table('blocks')
    op.drop_index(op.f('ix_auth_sessions_user_id'), table_name='auth_sessions')
    op.drop_table('auth_sessions')
    op.drop_index('uq_users_username_lower', table_name='users', postgresql_where=sa.text('username IS NOT NULL'))
    op.drop_index('ix_users_name_trgm', table_name='users', postgresql_using='gin', postgresql_ops={'first_name': 'gin_trgm_ops', 'last_name': 'gin_trgm_ops'})
    op.drop_table('users')
    for enum_name in ('message_type', 'member_role', 'chat_type', 'visibility'):
        op.execute(f'DROP TYPE IF EXISTS {enum_name}')
